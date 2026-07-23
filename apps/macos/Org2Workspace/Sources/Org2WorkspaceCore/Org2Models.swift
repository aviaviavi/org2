import Foundation

public struct CorpusIdentity: Codable, Hashable, Sendable {
  public let schema: String
  public let id: String
  public let name: String
  public let kind: String
}

public struct CorpusIdentityIssue: Decodable, Hashable, Sendable {
  public let path: String
  public let message: String
}

public struct CorpusIdentityStatus: Decodable, Sendable {
  public let schema: String
  public let root: String
  public let configFile: String
  public let identity: CorpusIdentity?
  public let valid: Bool
  public let issues: [CorpusIdentityIssue]
}

public struct WorkspaceCorpusMount: Codable, Hashable, Sendable, Identifiable {
  public let path: String
  public let corpusID: String?
  public let name: String
  public let kind: String?

  public var id: String { path }
  public var displayKind: String { kind?.capitalized ?? "Local" }
}

public struct WorkspaceResultCorpus: Decodable, Hashable, Sendable {
  public let schema: String
  public let id: String
  public let name: String
  public let kind: String
  public let root: String
}

public struct WorkspaceReadIssue: Decodable, Hashable, Sendable {
  public let root: String
  public let message: String
}

public enum WorkspaceReadScope: String, CaseIterable, Identifiable, Sendable {
  case activeCorpus
  case allCorpora

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .activeCorpus: "This Corpus"
    case .allCorpora: "All Corpora"
    }
  }
}

public struct AgentRunListPayload: Decodable, Sendable {
  public let schema: String?
  public let runs: [AgentRunItem]

  enum CodingKeys: String, CodingKey {
    case schema
    case runs
  }
}

enum AgentRunScope: String, CaseIterable, Identifiable {
  case active = "Active"
  case attention = "Needs attention"
  case completed = "Completed"
  case all = "All"

  var id: String { rawValue }

  func entries(in runs: [AgentRunItem]) -> [AgentRunScopeEntry] {
    switch self {
    case .attention:
      return Self.attentionEntries(in: runs)
    case .active, .completed, .all:
      return runs.filter(includes).map { AgentRunScopeEntry(run: $0) }
    }
  }

  func count(in runs: [AgentRunItem]) -> Int {
    entries(in: runs).count
  }

  private func includes(_ run: AgentRunItem) -> Bool {
    switch self {
    case .active: ["queued", "running"].contains(run.status)
    case .attention: run.needsAttention
    case .completed: run.isFinished
    case .all: true
    }
  }

  private static func attentionEntries(in runs: [AgentRunItem]) -> [AgentRunScopeEntry] {
    let orderedRuns = runs.sorted {
      $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
    }
    var latestRunIDBySeries: [String: AgentRunItem.ID] = [:]
    var failureCountBySeries: [String: Int] = [:]

    for run in orderedRuns {
      let key = run.failureSeriesKey
      if latestRunIDBySeries[key] == nil {
        latestRunIDBySeries[key] = run.id
      }
      if run.status == "failed" {
        failureCountBySeries[key, default: 0] += 1
      }
    }

    return orderedRuns.compactMap { run in
      if run.status == "failed" {
        let key = run.failureSeriesKey
        guard latestRunIDBySeries[key] == run.id else { return nil }
        return AgentRunScopeEntry(
          run: run,
          representedFailureCount: failureCountBySeries[key, default: 1]
        )
      }
      return run.needsAttention ? AgentRunScopeEntry(run: run) : nil
    }
  }
}

struct AgentRunScopeEntry: Identifiable, Equatable {
  let run: AgentRunItem
  let representedFailureCount: Int

  init(run: AgentRunItem, representedFailureCount: Int = 0) {
    self.run = run
    self.representedFailureCount = representedFailureCount
  }

  var id: AgentRunItem.ID { run.id }
}

struct RunCenterSection: Identifiable, Equatable {
  let id: String
  let sourceMeeting: AgentRunContextItem?
  let entries: [AgentRunScopeEntry]
}

enum RunCenterPresentation {
  static func sections(
    for entries: [AgentRunScopeEntry],
    allRuns: [AgentRunItem]
  ) -> [RunCenterSection] {
    var sections: [RunCenterSection] = []
    var sectionIndexByID: [String: Int] = [:]

    for entry in entries {
      let sourceMeeting = entry.run.sourceMeetingContext(in: allRuns)
      let sectionID = sourceMeeting.map { "meeting:\($0.fileReference ?? $0.ref)" } ?? "other"
      if let index = sectionIndexByID[sectionID] {
        let existing = sections[index]
        sections[index] = RunCenterSection(
          id: existing.id,
          sourceMeeting: existing.sourceMeeting,
          entries: existing.entries + [entry]
        )
      } else {
        sectionIndexByID[sectionID] = sections.count
        sections.append(RunCenterSection(
          id: sectionID,
          sourceMeeting: sourceMeeting,
          entries: [entry]
        ))
      }
    }
    return sections
  }
}

public struct AgentWorkflowListPayload: Decodable, Sendable {
  public let schema: String
  public let workflows: [AgentWorkflowItem]
}

public struct AgentWorkflowInputItem: Decodable, Hashable, Sendable, Identifiable {
  public let id: String
  public let description: String
  public let required: Bool
  public let `default`: String?
}

public struct AgentWorkflowTriggerItem: Decodable, Hashable, Sendable, Identifiable {
  public let id: String
  public let type: String
  public let enabled: Bool
  public let schedule: String?
  public let timezone: String?
}

public struct AgentWorkflowItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let version: String
  public let title: String
  public let description: String
  public let state: String
  public let instructions: String
  public let riskClass: String
  public let capabilities: [String]
  public let inputs: [AgentWorkflowInputItem]
  public let triggers: [AgentWorkflowTriggerItem]
  public let file: String
  public let legacyLocation: Bool
  public let sourceRunId: String?
  public let createdAt: String
  public let updatedAt: String

  public var scheduleTrigger: AgentWorkflowTriggerItem? {
    triggers.first { $0.id == "openclaw-schedule" && $0.type == "schedule" }
  }

  public var scheduleSummary: String {
    guard let trigger = scheduleTrigger, trigger.enabled, let schedule = trigger.schedule else {
      return "Manual"
    }
    if let timezone = trigger.timezone, !timezone.isEmpty { return "\(schedule) · \(timezone)" }
    return schedule
  }
}

public struct AgentRunItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let goal: String
  public let acceptanceCriteria: [String]
  public let status: String
  public let riskClass: String
  public let owner: String?
  public let assignee: String?
  public let workflowId: String?
  public let workflowVersion: String?
  public let providerPolicy: String?
  public let provider: String?
  public let model: String?
  public let capabilities: [String]
  public let context: [AgentRunContextItem]
  public let plan: [AgentRunStepItem]
  public let artifacts: [AgentRunArtifactItem]
  public let approvals: [AgentRunApprovalItem]
  public let validations: [AgentRunValidationItem]
  public let comments: [AgentRunCommentItem]
  public let events: [AgentRunEventItem]
  public let outcome: AgentRunOutcomeItem?
  public let parentRunId: String?
  public let createdAt: String
  public let updatedAt: String
  public let startedAt: String?
  public let completedAt: String?
  public let blockedReason: String?
  public let failure: String?

  public var pendingApprovalCount: Int { approvals.filter { $0.status == "pending" }.count }
  public var openClawExecApprovalID: String? {
    for comment in comments.reversed() {
      for line in comment.body.split(whereSeparator: \.isNewline) {
        let rawLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawLine.lowercased().hasPrefix("openclaw_key:") else { continue }
        let key = rawLine.dropFirst("OPENCLAW_KEY:".count)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = key.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 4,
              components[0].lowercased() == "draft",
              components[1].lowercased() == "exec"
        else { continue }
        let approvalID = components.dropFirst(3).joined(separator: ":")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !approvalID.isEmpty { return approvalID }
      }
    }
    return nil
  }
  public var completedStepCount: Int { plan.filter { $0.status == "completed" }.count }
  public var skippedStepCount: Int { plan.filter { $0.status == "skipped" }.count }
  public var latestValidations: [AgentRunValidationItem] {
    var seen = Set<String>()
    return validations.reversed().filter { seen.insert($0.name.lowercased()).inserted }.reversed()
  }
  public var attentionValidations: [AgentRunValidationItem] {
    latestValidations.filter { $0.status == "failed" || $0.status == "warning" }
  }
  public var isFinished: Bool {
    status == "completed" || status == "canceled"
  }
  public var needsAttention: Bool {
    guard !isFinished, !["queued", "running"].contains(status) else { return false }
    return pendingApprovalCount > 0
      || status == "blocked"
      || status == "failed"
      || status == "waiting-approval"
      || !attentionValidations.isEmpty
      || artifacts.contains { $0.reviewStatus == "review-required" }
  }
  public var progressText: String {
    guard !plan.isEmpty else { return "No plan" }
    if skippedStepCount > 0 {
      return "\(completedStepCount) completed · \(skippedStepCount) skipped"
    }
    return "\(completedStepCount)/\(plan.count) completed"
  }
  public var workflowDisplayName: String? { workflowId.map(Self.humanizedLabel) }
  public var sourceMeetingContext: AgentRunContextItem? {
    context.first(where: \.isMeetingReference)
  }
  public func sourceMeetingContext(in runs: [AgentRunItem]) -> AgentRunContextItem? {
    if let sourceMeetingContext { return sourceMeetingContext }
    let runsByID = runs.reduce(into: [String: AgentRunItem]()) { result, run in
      if result[run.id] == nil { result[run.id] = run }
    }
    var visited = Set([id])
    var ancestorID = parentRunId
    while let currentID = ancestorID,
          visited.insert(currentID).inserted,
          let ancestor = runsByID[currentID] {
      if let sourceMeetingContext = ancestor.sourceMeetingContext { return sourceMeetingContext }
      ancestorID = ancestor.parentRunId
    }
    return nil
  }
  fileprivate var failureSeriesKey: String {
    let normalizedGoal = goal
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return [workflowId ?? "", normalizedGoal, assignee ?? owner ?? ""]
      .joined(separator: "\u{1f}")
  }
  public var humanOutcomeSummary: String {
    if let summary = outcome?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
      return summary
    }
    if status == "completed" {
      let outputNames = artifacts.map(\.displayTitle)
      let outputSummary: String
      switch outputNames.count {
      case 0: outputSummary = "The run finished without recording a human-readable outcome."
      case 1: outputSummary = "Produced \(outputNames[0])."
      case 2: outputSummary = "Produced \(outputNames[0]) and \(outputNames[1])."
      default: outputSummary = "Produced \(outputNames.dropLast().joined(separator: ", ")), and \(outputNames.last!)."
      }
      guard !plan.isEmpty else { return outputSummary }
      let stepSummary = skippedStepCount > 0
        ? "Completed \(completedStepCount) steps; \(skippedStepCount) optional steps were skipped."
        : "Completed \(completedStepCount) of \(plan.count) steps."
      return "\(outputSummary) \(stepSummary)"
    }
    return goal
  }
  public var humanNextAction: String? {
    if let actions = outcome?.nextActions, !actions.isEmpty { return nil }
    if status == "completed" && !needsAttention { return "No action required" }
    return nil
  }
  public var clarificationPrompt: String? {
    guard status == "blocked",
          let prompt = blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines),
          !prompt.isEmpty,
          prompt.localizedCaseInsensitiveCompare("Blocked pending clarification") != .orderedSame
    else { return nil }
    return prompt
  }

  public func matchesRunFilter(_ query: String) -> Bool {
    let terms = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !terms.isEmpty else { return true }

    return terms.allSatisfy { runFilterText.contains($0) }
  }

  var runFilterText: String {
    var values = [
      id,
      goal,
      status,
      riskClass,
      owner,
      assignee,
      workflowId,
      workflowVersion,
      providerPolicy,
      provider,
      model,
      parentRunId,
      blockedReason,
      failure,
      outcome?.summary,
    ].compactMap { $0 }
    values.append(contentsOf: acceptanceCriteria)
    values.append(contentsOf: capabilities)
    values.append(contentsOf: outcome?.highlights ?? [])
    values.append(contentsOf: outcome?.nextActions ?? [])

    for item in context {
      values.append(contentsOf: [item.ref, item.title, item.citation, item.sha256].compactMap { $0 })
    }
    for item in plan {
      values.append(contentsOf: [item.id, item.title, item.kind, item.status, item.capability, item.detail].compactMap { $0 })
    }
    for item in artifacts {
      values.append(contentsOf: [item.id, item.path, item.role, item.title, item.mediaType, item.reviewStatus].compactMap { $0 })
    }
    for item in approvals {
      values.append(contentsOf: [
        item.id, item.title, item.action, item.riskClass, item.status,
        item.requestedRole, item.requestedFrom, item.decidedBy, item.note, item.receipt,
      ].compactMap { $0 })
    }
    for item in validations {
      values.append(contentsOf: [item.id, item.name, item.status, item.detail].compactMap { $0 })
    }
    for item in comments {
      values.append(contentsOf: [item.author, item.body].compactMap { $0 })
    }
    for item in events {
      values.append(contentsOf: [item.type, item.actor, item.detail].compactMap { $0 })
    }

    return values.joined(separator: "\n").lowercased()
  }

  public static func humanizedLabel(_ rawValue: String) -> String {
    rawValue
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}

public struct AgentRunOutcomeItem: Decodable, Hashable, Sendable {
  public let summary: String
  public let highlights: [String]
  public let nextActions: [String]
}

enum AgentRunTimestampPresentation {
  static func date(from rawValue: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: rawValue) { return date }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: rawValue)
  }

  static func displayText(
    for rawValue: String,
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    guard let date = date(from: rawValue) else { return rawValue }
    var localCalendar = calendar
    localCalendar.timeZone = timeZone

    let timeFormatter = DateFormatter()
    timeFormatter.locale = locale
    timeFormatter.timeZone = timeZone
    timeFormatter.dateStyle = .none
    timeFormatter.timeStyle = .short
    let time = timeFormatter.string(from: date)

    if localCalendar.isDate(date, inSameDayAs: now) {
      return "today at \(time)"
    }
    if let yesterday = localCalendar.date(byAdding: .day, value: -1, to: now),
       localCalendar.isDate(date, inSameDayAs: yesterday) {
      return "yesterday at \(time)"
    }

    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  static func detailText(
    for rawValue: String,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    guard let date = date(from: rawValue) else { return rawValue }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .full
    formatter.timeStyle = .medium
    let zone = timeZone.abbreviation(for: date).map { " \($0)" } ?? ""
    return formatter.string(from: date) + zone
  }
}

public struct AgentRunContextItem: Decodable, Hashable, Sendable {
  public let ref: String
  public let title: String?
  public let citation: String?
  public let sha256: String?

  public var fileReference: String? {
    let value = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value.hasPrefix("file:") { return String(value.dropFirst("file:".count)) }
    if value.contains("://") || value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
      return nil
    }
    return value
  }

  public var isMeetingReference: Bool {
    guard let fileReference else { return false }
    let normalized = fileReference.replacingOccurrences(of: "\\", with: "/").lowercased()
    return normalized.contains("/meetings/") || normalized.hasPrefix("meetings/")
  }

  public var displayTitle: String {
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      return title
    }
    guard let fileReference else { return ref }
    let stem = URL(fileURLWithPath: fileReference).deletingPathExtension().lastPathComponent
    let parts = stem.split(separator: "-").map(String.init)
    let hasDatedMeetingPrefix = parts.count >= 5
      && parts[0].count == 4
      && parts[1].count == 2
      && parts[2].count == 2
      && parts[3].count == 6
    if hasDatedMeetingPrefix {
      let meeting = AgentRunItem.humanizedLabel(parts.dropFirst(4).joined(separator: "-"))
      return meeting.isEmpty ? "Meeting · \(parts[0])-\(parts[1])-\(parts[2])" : "\(meeting) · \(parts[0])-\(parts[1])-\(parts[2])"
    }
    let label = AgentRunItem.humanizedLabel(stem)
    return label.isEmpty ? ref : label
  }
}

public struct AgentRunStepItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let kind: String
  public let status: String
  public let capability: String?
  public let detail: String?
}

public struct AgentRunArtifactItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let path: String
  public let role: String
  public let title: String?
  public let mediaType: String?
  public let sha256: String?
  public let reviewStatus: String?
  public let createdAt: String

  public var displayTitle: String {
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != path {
      return title
    }
    let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var label = AgentRunItem.humanizedLabel(filename)
    if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf",
       !label.localizedCaseInsensitiveContains("pdf") {
      label += " PDF"
    }
    return label.isEmpty ? path : label
  }

  public var isPDF: Bool {
    if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" {
      return true
    }
    return mediaType?
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() == "application/pdf"
  }

  public var roleDisplayText: String { AgentRunItem.humanizedLabel(role) }
}

public struct AgentRunApprovalItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let action: String
  public let riskClass: String
  public let status: String
  public let requestedRole: String?
  public let requestedFrom: String?
  public let requestedAt: String
  public let decidedAt: String?
  public let decidedBy: String?
  public let note: String?
  public let receipt: String?
}

public struct AgentRunValidationItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let status: String
  public let checkedAt: String
  public let detail: String?

  public var displayName: String { AgentRunItem.humanizedLabel(name) }
}

public struct AgentRunCommentItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let author: String
  public let body: String
  public let createdAt: String
}

public struct AgentRunEventItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let type: String
  public let at: String
  public let actor: String?
  public let detail: String?
}

public struct AgendaPayload: Decodable, Sendable {
  public let schema: String?
  public let range: AgendaRange
  public let overdue: [AgendaDay]
  public let days: [AgendaDay]
  public let skippedFiles: Int?
  public let workload: AgendaWorkload?
  public let corpora: [WorkspaceResultCorpus]?
  public let issues: [WorkspaceReadIssue]?

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case range
    case overdue
    case days
    case skippedFiles
    case workload
    case corpora
    case issues
  }

  public var totalItemCount: Int {
    (overdue + days).reduce(0) { $0 + $1.items.count }
  }

  public var todayItemCount: Int {
    guard let today = days.first(where: { $0.date == range.start }) else { return 0 }
    return today.items.count
  }

  public var upcomingItemCount: Int {
    days.filter { $0.date != range.start }.reduce(0) { $0 + $1.items.count }
  }
}

public struct AgendaRange: Decodable, Sendable {
  public let start: String
  public let end: String
  public let days: Int
}

public struct AgendaDay: Decodable, Identifiable, Sendable {
  public let date: String
  public let weekday: String
  public let items: [AgendaItem]
  public let groups: [AgendaGroup]?

  public var id: String { date }
}

public struct AgendaGroup: Decodable, Identifiable, Sendable {
  public let label: String
  public let items: [AgendaItem]

  public var id: String { label }
}

public struct AgendaItem: Decodable, Identifiable, Hashable, Sendable {
  public let todo: String?
  public let headline: String
  public let kind: String
  public let file: String
  public let line: Int
  public let body: String?
  public let level: Int?
  public let tags: [String]
  public let properties: [String: String]
  public let priority: String?
  public let time: String?
  public let effort: String?
  public let idValue: String?
  public let habit: HabitAgendaState?
  public let corpus: WorkspaceResultCorpus?

  enum CodingKeys: String, CodingKey {
    case todo
    case headline
    case kind
    case file
    case line
    case body
    case level
    case tags
    case properties
    case priority
    case time
    case effort
    case idValue = "id"
    case habit
    case corpus
  }

  public init(
    todo: String?,
    headline: String,
    kind: String,
    file: String,
    line: Int,
    body: String?,
    level: Int?,
    tags: [String],
    properties: [String: String],
    priority: String?,
    time: String?,
    effort: String?,
    idValue: String?,
    habit: HabitAgendaState?,
    corpus: WorkspaceResultCorpus? = nil
  ) {
    self.todo = todo
    self.headline = headline
    self.kind = kind
    self.file = file
    self.line = line
    self.body = body
    self.level = level
    self.tags = tags
    self.properties = properties
    self.priority = priority
    self.time = time
    self.effort = effort
    self.idValue = idValue
    self.habit = habit
    self.corpus = corpus
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    todo = try container.decodeIfPresent(String.self, forKey: .todo)
    headline = try container.decode(String.self, forKey: .headline)
    kind = try container.decode(String.self, forKey: .kind)
    file = try container.decode(String.self, forKey: .file)
    line = try container.decode(Int.self, forKey: .line)
    body = try container.decodeIfPresent(String.self, forKey: .body)
    level = try container.decodeIfPresent(Int.self, forKey: .level)
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
    priority = try container.decodeIfPresent(String.self, forKey: .priority)
    time = try container.decodeIfPresent(String.self, forKey: .time)
    effort = try container.decodeIfPresent(String.self, forKey: .effort)
    idValue = try container.decodeIfPresent(String.self, forKey: .idValue)
    habit = try container.decodeIfPresent(HabitAgendaState.self, forKey: .habit)
    corpus = try container.decodeIfPresent(WorkspaceResultCorpus.self, forKey: .corpus)
  }

  public var id: String {
    "\(file):\(line):\(kind):\(headline):\(idValue ?? "")"
  }

  public var lineForEditor: Int {
    max(1, line + 1)
  }

  public var isActionable: Bool {
    let normalized = (todo ?? "").uppercased()
    return normalized != "DONE" && normalized != "CANCELED" && normalized != "CANCELLED"
  }

  public func replacing(todo: String?) -> AgendaItem {
    AgendaItem(
      todo: todo,
      headline: headline,
      kind: kind,
      file: file,
      line: line,
      body: body,
      level: level,
      tags: tags,
      properties: properties,
      priority: priority,
      time: time,
      effort: effort,
      idValue: idValue,
      habit: habit,
      corpus: corpus
    )
  }

  public func matchesAgendaFilter(_ query: String) -> Bool {
    let terms = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)

    return matchesAgendaFilterTerms(terms)
  }

  func matchesAgendaFilterTerms(_ terms: [String]) -> Bool {
    guard !terms.isEmpty else { return true }

    return terms.allSatisfy { agendaFilterText.contains($0) }
  }

  var agendaFilterText: String {
    [
      todo,
      headline,
      kind,
      file,
      body,
      priority,
      effort,
      time,
      idValue,
      tags.joined(separator: " "),
      properties.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
    ]
      .compactMap { $0 }
      .joined(separator: "\n")
      .lowercased()
  }
}

public struct AssignedWorkItem: Identifiable, Hashable, Sendable {
  public let file: String
  public let line: Int
  public let headline: String
  public let todo: String?
  public let assignee: String
  public let status: String
  public let assignedAt: String?
  public let lastAgentUpdate: String?
  public let tags: [String]
  public let properties: [String: String]

  public init(
    file: String,
    line: Int,
    headline: String,
    todo: String?,
    assignee: String,
    status: String,
    assignedAt: String? = nil,
    lastAgentUpdate: String? = nil,
    tags: [String] = [],
    properties: [String: String] = [:]
  ) {
    self.file = file
    self.line = line
    self.headline = headline
    self.todo = todo
    self.assignee = assignee
    self.status = status
    self.assignedAt = assignedAt
    self.lastAgentUpdate = lastAgentUpdate
    self.tags = tags
    self.properties = properties
  }

  public var id: String {
    "\(file):\(line):\(assignee):\(status):\(headline)"
  }

  public var lineForEditor: Int {
    max(1, line)
  }
}

public enum RunsAndReviewPage: String, CaseIterable, Identifiable, Sendable {
  case runs = "Run Center"
  case review = "Review Queue"
  case workflows = "Workflows"

  public var id: String { rawValue }
}

public struct ApprovalItem: Identifiable, Hashable, Sendable, Decodable {
  public let kind: String?
  public let title: String
  public let status: String
  public let todo: String?
  public let level: Int?
  public let file: String
  public let line: Int
  public let idValue: String?
  public let properties: [String: String]
  public let body: String
  public let tags: [String]
  public let approvalId: String?
  public let action: String?
  public let riskClass: String?
  public let requestedRole: String?
  public let requestedFrom: String?
  public let requestedAt: String?
  public let runId: String?
  public let runGoal: String?
  public let runStatus: String?
  public let runPendingApprovalCount: Int?
  public let runApprovalCount: Int?
  public let runDecisionEffect: String?

  public init(
    title: String,
    status: String,
    todo: String?,
    level: Int?,
    file: String,
    line: Int,
    idValue: String?,
    properties: [String: String],
    body: String,
    tags: [String],
    kind: String? = nil,
    approvalId: String? = nil,
    action: String? = nil,
    riskClass: String? = nil,
    requestedRole: String? = nil,
    requestedFrom: String? = nil,
    requestedAt: String? = nil,
    runId: String? = nil,
    runGoal: String? = nil,
    runStatus: String? = nil,
    runPendingApprovalCount: Int? = nil,
    runApprovalCount: Int? = nil,
    runDecisionEffect: String? = nil
  ) {
    self.kind = kind
    self.title = title
    self.status = status
    self.todo = todo
    self.level = level
    self.file = file
    self.line = max(1, line)
    self.idValue = idValue
    self.properties = properties
    self.body = body
    self.tags = tags
    self.approvalId = approvalId
    self.action = action
    self.riskClass = riskClass
    self.requestedRole = requestedRole
    self.requestedFrom = requestedFrom
    self.requestedAt = requestedAt
    self.runId = runId
    self.runGoal = runGoal
    self.runStatus = runStatus
    self.runPendingApprovalCount = runPendingApprovalCount
    self.runApprovalCount = runApprovalCount
    self.runDecisionEffect = runDecisionEffect
  }

  public var id: String {
    if let runId, let approvalId { return "run:\(runId):\(approvalId)" }
    return "\(file):\(line):\(idValue ?? title)"
  }

  public var isRunApproval: Bool { kind == "run" && runId != nil && approvalId != nil }

  public var sourceLabel: String {
    if let runId { return "Run \(runId)" }
    return "\(file):\(line)"
  }

  public var runDependencyText: String? {
    guard isRunApproval else { return nil }
    return runDecisionEffect
  }

  public var discussionText: String {
    """
    OpenClaw approval thread:

    \(Org2Display.cleanInline(title))
    Source: \(sourceLabel)
    Status: \(status)
    \(runGoal.map { "Run: \($0)" } ?? "")
    \(runDependencyText ?? "")

    \(Org2Display.cleanBlock(body).trimmedForDisplay(maxCharacters: 900))
    """
  }

  public func agendaItem() -> AgendaItem {
    AgendaItem(
      todo: todo,
      headline: title,
      kind: "Approval",
      file: file,
      line: line - 1,
      body: body,
      level: level,
      tags: tags,
      properties: properties,
      priority: nil,
      time: nil,
      effort: nil,
      idValue: idValue,
      habit: nil
    )
  }

  public func matchesApprovalFilter(_ query: String) -> Bool {
    let terms = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !terms.isEmpty else { return true }

    return terms.allSatisfy { approvalFilterText.contains($0) }
  }

  var approvalFilterText: String {
    [
      title,
      status,
      todo,
      file,
      idValue,
      body,
      approvalId,
      action,
      riskClass,
      requestedRole,
      requestedFrom,
      runId,
      runGoal,
      runStatus,
      runDecisionEffect,
      tags.joined(separator: " "),
      properties.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
    ]
      .compactMap { $0 }
      .joined(separator: "\n")
      .lowercased()
  }
}

public struct HabitAgendaState: Decodable, Hashable, Sendable {
  public let marker: String
  public let streak: Int
  public let closedDates: [String]
}

public struct AgendaWorkload: Decodable, Sendable {
  public let totalMinutes: Int
  public let byDate: [String: Int]
  public let byGroup: [String: Int]
  public let byTag: [String: Int]
}

public struct SearchPayload: Decodable, Sendable {
  public let schema: String?
  public let query: String
  public let mode: String
  public let sort: String
  public let results: [SearchResult]
  public let corpora: [WorkspaceResultCorpus]?
  public let issues: [WorkspaceReadIssue]?

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case query
    case mode
    case sort
    case results
    case corpora
    case issues
  }
}

public struct SearchResult: Decodable, Identifiable, Hashable, Sendable {
  public let file: String
  public let line: Int
  public let lineEnd: Int?
  public let heading: String?
  public let headingLine: Int?
  public let headingLevel: Int?
  public let headingAncestry: [HeadingRef]?
  public let idValue: String?
  public let todo: String?
  public let tags: [String]
  public let snippet: String
  public let sourceRange: SourceRange?
  public let matchedLines: [MatchedLine]?
  public let date: String?
  public let corpus: WorkspaceResultCorpus?

  enum CodingKeys: String, CodingKey {
    case file
    case line
    case lineEnd
    case heading
    case headingLine
    case headingLevel
    case headingAncestry
    case idValue = "id"
    case todo
    case tags
    case snippet
    case sourceRange
    case matchedLines
    case date
    case corpus
  }

  public init(
    file: String,
    line: Int,
    lineEnd: Int?,
    heading: String?,
    headingLine: Int?,
    headingLevel: Int?,
    headingAncestry: [HeadingRef]?,
    idValue: String?,
    todo: String?,
    tags: [String],
    snippet: String,
    sourceRange: SourceRange?,
    matchedLines: [MatchedLine]?,
    date: String?,
    corpus: WorkspaceResultCorpus? = nil
  ) {
    self.file = file
    self.line = line
    self.lineEnd = lineEnd
    self.heading = heading
    self.headingLine = headingLine
    self.headingLevel = headingLevel
    self.headingAncestry = headingAncestry
    self.idValue = idValue
    self.todo = todo
    self.tags = tags
    self.snippet = snippet
    self.sourceRange = sourceRange
    self.matchedLines = matchedLines
    self.date = date
    self.corpus = corpus
  }

  public var id: String {
    "\(file):\(line):\(lineEnd ?? line):\(snippet)"
  }

  public var title: String {
    heading?.isEmpty == false ? heading! : snippet
  }

  public var lineForEditor: Int {
    max(1, line)
  }

  public var isActiveTodo: Bool {
    guard let todo else { return false }
    return !Self.isTerminalTodoStatus(todo)
  }

  public var isTerminalTodo: Bool {
    guard let todo else { return false }
    return Self.isTerminalTodoStatus(todo)
  }

  private static func isTerminalTodoStatus(_ status: String) -> Bool {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return normalized == "DONE" || normalized == "CANCELED" || normalized == "CANCELLED"
  }
}

public struct SearchResultGroup: Identifiable, Hashable, Sendable {
  public let file: String
  public let representative: SearchResult
  public let results: [SearchResult]

  public init?(file: String, results: [SearchResult]) {
    guard let representative = results.first else { return nil }
    self.file = file
    self.representative = representative
    self.results = results
  }

  public var id: String { file }

  public var additionalCount: Int {
    max(0, results.count - 1)
  }
}

public enum OpenClawChatSearchMatchKind: String, Hashable, Sendable {
  case threadTitle
  case messageText
}

public struct OpenClawChatSearchResult: Identifiable, Hashable, Sendable {
  public let threadID: UUID
  public let messageID: UUID?
  public let matchKind: OpenClawChatSearchMatchKind
  public let title: String
  public let snippet: String
  public let messageCount: Int
  public let updatedAt: Date

  public init(
    threadID: UUID,
    messageID: UUID?,
    matchKind: OpenClawChatSearchMatchKind,
    title: String,
    snippet: String,
    messageCount: Int,
    updatedAt: Date
  ) {
    self.threadID = threadID
    self.messageID = messageID
    self.matchKind = matchKind
    self.title = title
    self.snippet = snippet
    self.messageCount = messageCount
    self.updatedAt = updatedAt
  }

  public var id: String {
    "\(threadID.uuidString):\(messageID?.uuidString ?? "thread")"
  }
}

public enum WorkspaceTextSearchCategory: Int, CaseIterable, Identifiable, Hashable, Sendable {
  case activeTodos
  case files
  case chatThreads
  case pages
  case entries
  case chatMessages
  case corpusText

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .activeTodos: "Active TODOs"
    case .files: "Files"
    case .chatThreads: "Chat Threads"
    case .pages: "Pages"
    case .entries: "Entries"
    case .chatMessages: "Chat Messages"
    case .corpusText: "Corpus Text"
    }
  }
}

public enum WorkspaceTextSearchItem: Identifiable, Hashable, Sendable {
  case activeTodo(SearchResult)
  case file(CorpusFile)
  case chatThread(OpenClawChatSearchResult)
  case page(OrgRoamNodeReference)
  case entry(SearchResult)
  case chatMessage(OpenClawChatSearchResult)
  case corpusText(SearchResult)

  public var id: String {
    switch self {
    case .activeTodo(let result): "todo:\(result.id)"
    case .file(let file): "file:\(file.id)"
    case .chatThread(let result): "chat-thread:\(result.id)"
    case .page(let node): "page:\(node.id)"
    case .entry(let result): "entry:\(result.id)"
    case .chatMessage(let result): "chat-message:\(result.id)"
    case .corpusText(let result): "corpus-text:\(result.id)"
    }
  }

  public var category: WorkspaceTextSearchCategory {
    switch self {
    case .activeTodo: .activeTodos
    case .file: .files
    case .chatThread: .chatThreads
    case .page: .pages
    case .entry: .entries
    case .chatMessage: .chatMessages
    case .corpusText: .corpusText
    }
  }
}

public struct WorkspaceTextSearchSection: Identifiable, Hashable, Sendable {
  public let category: WorkspaceTextSearchCategory
  public let items: [WorkspaceTextSearchItem]

  public var id: WorkspaceTextSearchCategory { category }
}

public struct HeadingRef: Decodable, Hashable, Sendable {
  public let level: Int
  public let title: String
  public let line: Int
  public let lineNumber: Int
}

public struct SourceRange: Decodable, Hashable, Sendable {
  public let startLine: Int
  public let endLine: Int
}

public struct MatchedLine: Decodable, Hashable, Sendable {
  public let line: Int
  public let snippet: String
}

public struct BacklinksPayload: Decodable, Sendable {
  public let schema: String?
  public let id: String
  public let backlinks: [BacklinkItem]

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case id
    case backlinks
  }
}

public struct BacklinkItem: Decodable, Identifiable, Hashable, Sendable {
  public let srcId: String?
  public let srcTitle: String
  public let file: String
  public let line: Int
  public let context: String

  public var id: String {
    "\(file):\(line):\(srcId ?? ""):\(context)"
  }

  public var lineForEditor: Int {
    max(1, line + 1)
  }
}

public struct EntrySource: Identifiable, Hashable, Sendable {
  public let file: String
  public let startLine: Int
  public let endLineExclusive: Int
  public let text: String
  public let isSubtree: Bool
  public let isEditable: Bool

  public init(
    file: String,
    startLine: Int,
    endLineExclusive: Int,
    text: String,
    isSubtree: Bool,
    isEditable: Bool = true
  ) {
    self.file = file
    self.startLine = startLine
    self.endLineExclusive = endLineExclusive
    self.text = text
    self.isSubtree = isSubtree
    self.isEditable = isEditable
  }

  public var id: String {
    "\(file):\(startLine):\(endLineExclusive)"
  }

  public var displayRange: String {
    if endLineExclusive <= startLine + 1 { return "\(startLine)" }
    return "\(startLine)-\(endLineExclusive - 1)"
  }
}

public enum OrgInsertBlockKind: String, CaseIterable, Identifiable, Sendable {
  case paragraph
  case heading
  case todo
  case table
  case divider
  case image
  case video
  case properties
  case quote
  case source

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .paragraph: "Text"
    case .heading: "Heading"
    case .todo: "TODO"
    case .table: "Table"
    case .divider: "Divider"
    case .image: "Image"
    case .video: "Video"
    case .properties: "Properties"
    case .quote: "Quote"
    case .source: "Source"
    }
  }

  public var systemImage: String {
    switch self {
    case .paragraph: "text.alignleft"
    case .heading: "textformat.size"
    case .todo: "checklist"
    case .table: "tablecells"
    case .divider: "minus"
    case .image: "photo"
    case .video: "film"
    case .properties: "tag"
    case .quote: "quote.opening"
    case .source: "chevron.left.forwardslash.chevron.right"
    }
  }

  public var slashCommand: String {
    switch self {
    case .paragraph: "text"
    case .heading: "heading"
    case .todo: "todo"
    case .table: "table"
    case .divider: "divider"
    case .image: "image"
    case .video: "video"
    case .properties: "properties"
    case .quote: "quote"
    case .source: "source"
    }
  }
}

public enum OrgBlockMoveDirection: Equatable, Sendable {
  case up
  case down
}

public struct CorpusFile: Identifiable, Hashable, Sendable {
  public let path: String
  public let relativePath: String
  public let directory: String
  public let name: String
  public let modifiedAt: Date?
  public let byteCount: Int64?

  public init(path: String, relativePath: String, modifiedAt: Date?, byteCount: Int64?) {
    self.path = path
    self.relativePath = relativePath
    let directory = NSString(string: relativePath).deletingLastPathComponent
    self.directory = directory == "." || directory == "/" ? "" : directory
    self.name = NSString(string: relativePath).lastPathComponent
    self.modifiedAt = modifiedAt
    self.byteCount = byteCount
  }

  public var id: String { path }
}

public struct OrgCryptRecipientFile: Identifiable, Hashable, Sendable {
  public let path: String
  public let relativePath: String
  public let name: String

  public init(path: String, relativePath: String) {
    self.path = path
    self.relativePath = relativePath
    self.name = NSString(string: relativePath).lastPathComponent
  }

  public var id: String { path }
}

public enum EntrySourceMode: String, CaseIterable, Identifiable, Sendable {
  case entry
  case page

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .entry: "Entry"
    case .page: "Page"
    }
  }
}

public struct OpenClawThread: Identifiable, Hashable, Sendable {
  public let title: String
  public let file: String
  public let line: Int
  public let zone: String
  public let modifiedAt: Date?
  public let idValue: String?

  public init(title: String, file: String, line: Int = 1, zone: String, modifiedAt: Date?, idValue: String? = nil) {
    self.title = title
    self.file = file
    self.line = line
    self.zone = zone
    self.modifiedAt = modifiedAt
    self.idValue = idValue
  }

  public var id: String { file }

  public var lineForEditor: Int {
    max(1, line)
  }
}

public struct MeetingWorkspaceItem: Identifiable, Hashable, Sendable {
  public let title: String
  public let file: String
  public let line: Int
  public let recordedAt: String?
  public let modifiedAt: Date?
  public let audioArtifact: String?
  public let systemAudioArtifact: String?
  public let transcriptArtifact: String?
  public let transcriptionStatus: String?
  public let idValue: String?

  public init(
    title: String,
    file: String,
    line: Int = 1,
    recordedAt: String?,
    modifiedAt: Date?,
    audioArtifact: String?,
    systemAudioArtifact: String? = nil,
    transcriptArtifact: String?,
    transcriptionStatus: String?,
    idValue: String?
  ) {
    self.title = title
    self.file = file
    self.line = line
    self.recordedAt = recordedAt
    self.modifiedAt = modifiedAt
    self.audioArtifact = audioArtifact
    self.systemAudioArtifact = systemAudioArtifact
    self.transcriptArtifact = transcriptArtifact
    self.transcriptionStatus = transcriptionStatus
    self.idValue = idValue
  }

  public var id: String { file }

  public var lineForEditor: Int {
    max(1, line)
  }
}

public struct MeetingProcessingItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let status: String
  public let startedAt: Date

  public init(id: String, title: String, status: String, startedAt: Date) {
    self.id = id
    self.title = title
    self.status = status
    self.startedAt = startedAt
  }
}

public struct OpenClawChatMessage: Identifiable, Hashable, Codable, Sendable {
  public enum Role: String, Codable, Sendable {
    case user
    case assistant
    case system
  }

  public enum DeliveryStatus: String, Codable, Sendable {
    case sent
    case sending
    case failed
    case interrupted
  }

  public let id: UUID
  public let role: Role
  public let content: String
  public let attachments: [OpenClawChatAttachment]
  public let createdAt: Date
  public let changeSummary: OpenClawCorpusChangeSummary?
  public let responseTrace: OpenClawResponseTrace?
  public let sendFailure: String?
  public let deliveryStatus: DeliveryStatus

  public init(
    id: UUID = UUID(),
    role: Role,
    content: String,
    attachments: [OpenClawChatAttachment] = [],
    createdAt: Date = Date(),
    changeSummary: OpenClawCorpusChangeSummary? = nil,
    responseTrace: OpenClawResponseTrace? = nil,
    sendFailure: String? = nil,
    deliveryStatus: DeliveryStatus = .sent
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.attachments = attachments
    self.createdAt = createdAt
    self.changeSummary = changeSummary
    self.responseTrace = responseTrace
    self.sendFailure = sendFailure
    self.deliveryStatus = role == .user ? deliveryStatus : .sent
  }

  enum CodingKeys: String, CodingKey {
    case id
    case role
    case content
    case attachments
    case createdAt
    case changeSummary
    case responseTrace
    case sendFailure
    case deliveryStatus
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    role = try container.decode(Role.self, forKey: .role)
    content = try container.decode(String.self, forKey: .content)
    attachments = try container.decodeIfPresent([OpenClawChatAttachment].self, forKey: .attachments) ?? []
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    changeSummary = try container.decodeIfPresent(OpenClawCorpusChangeSummary.self, forKey: .changeSummary)
    responseTrace = try container.decodeIfPresent(OpenClawResponseTrace.self, forKey: .responseTrace)
    sendFailure = try container.decodeIfPresent(String.self, forKey: .sendFailure)
    deliveryStatus = role == .user
      ? (try container.decodeIfPresent(DeliveryStatus.self, forKey: .deliveryStatus) ?? (sendFailure == nil ? .sent : .failed))
      : .sent
  }

  public func replacingSendFailure(_ nextSendFailure: String?) -> OpenClawChatMessage {
    OpenClawChatMessage(
      id: id,
      role: role,
      content: content,
      attachments: attachments,
      createdAt: createdAt,
      changeSummary: changeSummary,
      responseTrace: responseTrace,
      sendFailure: nextSendFailure,
      deliveryStatus: nextSendFailure == nil ? .sent : .failed
    )
  }

  public func replacingDeliveryStatus(
    _ nextDeliveryStatus: DeliveryStatus,
    sendFailure nextSendFailure: String? = nil
  ) -> OpenClawChatMessage {
    OpenClawChatMessage(
      id: id,
      role: role,
      content: content,
      attachments: attachments,
      createdAt: createdAt,
      changeSummary: changeSummary,
      responseTrace: responseTrace,
      sendFailure: nextSendFailure,
      deliveryStatus: nextDeliveryStatus
    )
  }

  public func replacingChangeSummary(_ nextChangeSummary: OpenClawCorpusChangeSummary?) -> OpenClawChatMessage {
    OpenClawChatMessage(
      id: id,
      role: role,
      content: content,
      attachments: attachments,
      createdAt: createdAt,
      changeSummary: nextChangeSummary,
      responseTrace: responseTrace,
      sendFailure: sendFailure,
      deliveryStatus: deliveryStatus
    )
  }
}

public struct OpenClawResponseTrace: Hashable, Codable, Sendable {
  public let reasoning: String
  public let activities: [OpenClawRunActivity]

  public init(reasoning: String = "", activities: [OpenClawRunActivity] = []) {
    self.reasoning = reasoning
    self.activities = activities
  }

  public var isEmpty: Bool {
    reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activities.isEmpty
  }
}

public struct OpenClawChatAttachment: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let fileName: String
  public let mimeType: String
  public let data: Data

  public init(
    id: UUID = UUID(),
    fileName: String,
    mimeType: String,
    data: Data
  ) {
    self.id = id
    self.fileName = fileName
    self.mimeType = mimeType
    self.data = data
  }

  public var byteCount: Int {
    data.count
  }

  public var dataURLString: String {
    "data:\(mimeType);base64,\(data.base64EncodedString())"
  }
}

public struct OpenClawResourceReference: Hashable, Codable, Sendable {
  public enum Kind: String, Hashable, Codable, Sendable {
    case heading
    case file
  }

  public let key: String
  public let kind: Kind
  public let title: String
  public let file: String
  public let line: Int
  public let idValue: String?

  public init(
    key: String,
    kind: Kind,
    title: String,
    file: String,
    line: Int,
    idValue: String? = nil
  ) {
    self.key = key
    self.kind = kind
    self.title = title
    self.file = file
    self.line = max(1, line)
    self.idValue = idValue
  }
}

public struct OpenClawChatThread: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let title: String
  public let createdAt: Date
  public let updatedAt: Date
  public let sessionKey: String
  public let messages: [OpenClawChatMessage]
  public let isPinned: Bool
  public let isArchived: Bool
  public let unreadMessageCount: Int
  public let resource: OpenClawResourceReference?

  public init(
    id: UUID = UUID(),
    title: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    sessionKey: String,
    messages: [OpenClawChatMessage] = [],
    isPinned: Bool = false,
    isArchived: Bool = false,
    unreadMessageCount: Int = 0,
    resource: OpenClawResourceReference? = nil
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.sessionKey = sessionKey
    self.messages = messages
    self.isPinned = isPinned
    self.isArchived = isArchived
    self.unreadMessageCount = max(0, unreadMessageCount)
    self.resource = resource
  }

  public var messageCount: Int {
    messages.count
  }

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case createdAt
    case updatedAt
    case sessionKey
    case messages
    case isPinned
    case isArchived
    case unreadMessageCount
    case resource
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    sessionKey = try container.decode(String.self, forKey: .sessionKey)
    messages = try container.decode([OpenClawChatMessage].self, forKey: .messages)
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    unreadMessageCount = max(0, try container.decodeIfPresent(Int.self, forKey: .unreadMessageCount) ?? 0)
    resource = try container.decodeIfPresent(OpenClawResourceReference.self, forKey: .resource)
  }

  public func replacingOpenClawChatMetadata(
    title nextTitle: String? = nil,
    sessionKey nextSessionKey: String? = nil,
    isPinned nextIsPinned: Bool? = nil,
    isArchived nextIsArchived: Bool? = nil,
    unreadMessageCount nextUnreadMessageCount: Int? = nil
  ) -> OpenClawChatThread {
    OpenClawChatThread(
      id: id,
      title: nextTitle ?? title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      sessionKey: nextSessionKey ?? sessionKey,
      messages: messages,
      isPinned: nextIsPinned ?? isPinned,
      isArchived: nextIsArchived ?? isArchived,
      unreadMessageCount: nextUnreadMessageCount ?? unreadMessageCount,
      resource: resource
    )
  }

  public func replacingMessages(_ nextMessages: [OpenClawChatMessage]) -> OpenClawChatThread {
    OpenClawChatThread(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: nextMessages.last?.createdAt ?? updatedAt,
      sessionKey: sessionKey,
      messages: nextMessages,
      isPinned: isPinned,
      isArchived: isArchived,
      unreadMessageCount: unreadMessageCount,
      resource: resource
    )
  }
}

public struct OpenClawCorpusChangeSummary: Hashable, Codable, Sendable {
  public let files: [OpenClawCorpusFileChange]

  public init(files: [OpenClawCorpusFileChange]) {
    self.files = files
  }

  public var changedFileCount: Int {
    files.count
  }

  public var totalInsertions: Int {
    files.reduce(0) { $0 + $1.insertions }
  }

  public var totalDeletions: Int {
    files.reduce(0) { $0 + $1.deletions }
  }

  public var title: String {
    let noun = changedFileCount == 1 ? "file" : "files"
    if files.allSatisfy({ $0.status == .created }) {
      return "Created \(changedFileCount) \(noun)"
    }
    if files.allSatisfy({ $0.status == .deleted }) {
      return "Deleted \(changedFileCount) \(noun)"
    }
    return "Edited \(changedFileCount) \(noun)"
  }
}

public struct OpenClawCorpusFileChange: Identifiable, Hashable, Codable, Sendable {
  public enum Status: String, Hashable, Codable, Sendable {
    case created
    case modified
    case deleted
  }

  public let relativePath: String
  public let status: Status
  public let insertions: Int
  public let deletions: Int

  public init(relativePath: String, status: Status, insertions: Int, deletions: Int) {
    self.relativePath = relativePath
    self.status = status
    self.insertions = insertions
    self.deletions = deletions
  }

  public var id: String {
    relativePath
  }
}

public struct OpenClawChatCompletionPayload: Decodable, Sendable {
  public let choices: [Choice]

  public struct Choice: Decodable, Sendable {
    public let message: Message?
  }

  public struct Message: Decodable, Sendable {
    public let role: String?
    public let content: String?
  }

  public var assistantText: String {
    choices
      .compactMap { $0.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }
}

public struct OpenClawFileReference: Identifiable, Hashable, Sendable {
  public static let deepLinkScheme = "org2-workspace"

  public let path: String
  public let line: Int?

  public init(path: String, line: Int?) {
    let parsed = Self.cleanPathAndLine(path)
    self.path = parsed.path
    self.line = line ?? parsed.line
  }

  public var id: String {
    "\(path):\(line ?? 0)"
  }

  public var displayTitle: String {
    let title = URL(fileURLWithPath: path).lastPathComponent
    guard let line else { return title }
    return "\(title):\(line)"
  }

  public static func extract(from text: String, limit: Int = 8) -> [OpenClawFileReference] {
    let pattern = #"(?<![A-Za-z0-9_./~-])((?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:(?::|#)[Ll]?(\d+)(?:-[Ll]?\d+)?)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    var references: [OpenClawFileReference] = []
    var seen = Set<String>()

    for match in matches {
      guard references.count < limit, match.numberOfRanges >= 2 else { break }
      let rawPath = nsText.substring(with: match.range(at: 1))
      let line: Int?
      if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
        line = Int(nsText.substring(with: match.range(at: 2)))
      } else {
        line = nil
      }

      let reference = OpenClawFileReference(path: rawPath, line: line)
      guard !reference.path.isEmpty, seen.insert(reference.id).inserted else { continue }
      references.append(reference)
    }

    return references
  }

  public static func fromLinkTarget(_ raw: String) -> OpenClawFileReference? {
    let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    let lowercased = target.lowercased()
    let isFileTarget = lowercased.hasPrefix("file:")
      || lowercased.range(
        of: #"\.(?:org2?|md)(?:(?::|#)l?\d+(?:-l?\d+)?)?$"#,
        options: .regularExpression
      ) != nil
    guard isFileTarget else { return nil }

    return OpenClawFileReference(path: target, line: nil)
  }

  public var deepLinkURL: URL? {
    var components = URLComponents()
    components.scheme = Self.deepLinkScheme
    components.host = "open-file"
    components.queryItems = [
      URLQueryItem(name: "path", value: path)
    ]
    if let line {
      components.queryItems?.append(URLQueryItem(name: "line", value: "\(line)"))
    }
    return components.url
  }

  public static func fromDeepLinkURL(_ url: URL) -> OpenClawFileReference? {
    guard url.scheme == deepLinkScheme, url.host == "open-file" else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let path = components?.queryItems?.first(where: { $0.name == "path" })?.value
    let line = components?.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
    guard let path, !path.isEmpty else { return nil }
    return OpenClawFileReference(path: path, line: line)
  }

  private static func cleanPathAndLine(_ raw: String) -> (path: String, line: Int?) {
    var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.hasPrefix("file://") {
      path = String(path.dropFirst("file://".count)).removingPercentEncoding ?? String(path.dropFirst("file://".count))
    } else if path.hasPrefix("file:") {
      path = String(path.dropFirst("file:".count)).removingPercentEncoding ?? String(path.dropFirst("file:".count))
    }
    while let last = path.last, [".", ",", ";", ":"].contains(String(last)) {
      path.removeLast()
    }

    let nsPath = path as NSString
    let fullRange = NSRange(location: 0, length: nsPath.length)
    if let regex = try? NSRegularExpression(
      pattern: #"^(.*\.(?:org2?|md))(?::|#)[Ll]?(\d+)(?:-[Ll]?\d+)?$"#
    ),
       let match = regex.firstMatch(in: path, range: fullRange),
       match.numberOfRanges == 3 {
      let cleanPath = nsPath.substring(with: match.range(at: 1))
      let line = Int(nsPath.substring(with: match.range(at: 2)))
      return (cleanPath, line)
    }

    return (path, nil)
  }
}

public struct OrgRoamNodeReference: Identifiable, Hashable, Sendable {
  public let idValue: String?
  public let title: String
  public let aliases: [String]
  public let file: String
  public let line: Int
  public let isPageNode: Bool

  public init(idValue: String?, title: String, aliases: [String] = [], file: String, line: Int, isPageNode: Bool = false) {
    let trimmedID = idValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.idValue = trimmedID.isEmpty ? nil : trimmedID
    self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    self.aliases = aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    self.file = file
    self.line = max(1, line)
    self.isPageNode = isPageNode
  }

  public var id: String {
    "\(file):\(line):\(idValue ?? title)"
  }

  public var fileReference: OpenClawFileReference {
    OpenClawFileReference(path: file, line: line)
  }

  public var preferredLinkTarget: String {
    if let idValue {
      return "id:\(idValue)"
    }
    return file
  }
}

public struct OrgRoamResolvedLink: Equatable, Sendable {
  public let title: String
  public let fileReference: OpenClawFileReference

  public init(title: String, fileReference: OpenClawFileReference) {
    self.title = title
    self.fileReference = fileReference
  }
}

public struct OrgRoamLinkResolver: Equatable, Sendable {
  public static let empty = OrgRoamLinkResolver(nodes: [])

  public let nodes: [OrgRoamNodeReference]
  public let signature: String
  private let nodesByID: [String: OrgRoamNodeReference]
  private let nodesByTitle: [String: OrgRoamNodeReference]
  private let nodeCandidatesByTitle: [String: [OrgRoamNodeReference]]

  public init(nodes: [OrgRoamNodeReference]) {
    self.nodes = nodes

    var idCandidates: [String: [OrgRoamNodeReference]] = [:]
    var titleCandidates: [String: [OrgRoamNodeReference]] = [:]
    for node in nodes {
      if let idValue = node.idValue {
        idCandidates[Self.normalizedID(idValue), default: []].append(node)
      }

      for title in [node.title] + node.aliases {
        let key = Self.normalizedTitle(title)
        guard !key.isEmpty else { continue }
        if titleCandidates[key]?.contains(node) != true {
          titleCandidates[key, default: []].append(node)
        }
      }
    }

    nodesByID = idCandidates.compactMapValues { candidates in
      candidates.count == 1 ? candidates[0] : nil
    }
    nodesByTitle = titleCandidates.compactMapValues { candidates in
      candidates.count == 1 ? candidates[0] : nil
    }
    nodeCandidatesByTitle = titleCandidates.mapValues(Self.rankedCandidates)
    signature = Self.makeSignature(nodes)
  }

  public func resolve(target rawTarget: String) -> OrgRoamResolvedLink? {
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    let lowercased = target.lowercased()
    let node: OrgRoamNodeReference?
    if lowercased.hasPrefix("id:") {
      node = nodesByID[Self.normalizedID(String(target.dropFirst(3)))]
    } else {
      node = nodesByTitle[Self.normalizedTitle(target)]
    }

    guard let node else { return nil }
    return OrgRoamResolvedLink(title: node.title, fileReference: node.fileReference)
  }

  public func exactCandidates(for rawTarget: String) -> [OrgRoamNodeReference] {
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return [] }
    if target.lowercased().hasPrefix("id:") {
      return nodesByID[Self.normalizedID(String(target.dropFirst(3)))].map { [$0] } ?? []
    }
    return nodeCandidatesByTitle[Self.normalizedTitle(target)] ?? []
  }

  public func searchCandidates(matching rawQuery: String, limit: Int = 6) -> [OrgRoamNodeReference] {
    let query = Self.normalizedTitle(rawQuery)
    guard !query.isEmpty else { return [] }
    let scored = nodes.compactMap { node -> (OrgRoamNodeReference, Int)? in
      let labels = [node.title] + node.aliases
      var bestScore: Int?
      for label in labels {
        let normalized = Self.normalizedTitle(label)
        if normalized == query {
          bestScore = min(bestScore ?? 0, 0)
        } else if normalized.hasPrefix(query) {
          bestScore = min(bestScore ?? 1, 1)
        } else if normalized.contains(query) {
          bestScore = min(bestScore ?? 2, 2)
        }
      }
      return bestScore.map { (node, $0) }
    }
    return scored
      .sorted {
        if $0.1 != $1.1 { return $0.1 < $1.1 }
        return Self.compareRankedCandidates($0.0, $1.0)
      }
      .map(\.0)
      .prefix(limit)
      .map { $0 }
  }

  public static func normalizedTitle(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
  }

  private static func normalizedID(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func makeSignature(_ nodes: [OrgRoamNodeReference]) -> String {
    var hasher = Hasher()
    hasher.combine(nodes.count)
    for node in nodes.sorted(by: { $0.id < $1.id }) {
      hasher.combine(node.idValue)
      hasher.combine(node.title)
      hasher.combine(node.aliases)
      hasher.combine(node.file)
      hasher.combine(node.line)
      hasher.combine(node.isPageNode)
    }
    return "\(nodes.count):\(hasher.finalize())"
  }

  private static func rankedCandidates(_ candidates: [OrgRoamNodeReference]) -> [OrgRoamNodeReference] {
    candidates.sorted(by: compareRankedCandidates)
  }

  private static func compareRankedCandidates(_ lhs: OrgRoamNodeReference, _ rhs: OrgRoamNodeReference) -> Bool {
    if lhs.isPageNode != rhs.isPageNode {
      return lhs.isPageNode
    }
    let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    if titleOrder != .orderedSame {
      return titleOrder == .orderedAscending
    }
    let pathOrder = lhs.file.localizedStandardCompare(rhs.file)
    if pathOrder != .orderedSame {
      return pathOrder == .orderedAscending
    }
    return lhs.line < rhs.line
  }
}

public enum OrgInlineSpan: Equatable, Sendable {
  case text(String)
  case code(String)
  case bold(String)
  case italic(String)
  case underline(String)
  case strike(String)
  case timestamp(OrgInlineTimestamp)
  case link(label: String, target: String, fileReference: OpenClawFileReference?)
}

public struct OrgInlineTimestamp: Equatable, Sendable {
  public let raw: String
  public let dateLabel: String
  public let timeLabel: String?
  public let detail: String?

  public init(raw: String, dateLabel: String, timeLabel: String? = nil, detail: String? = nil) {
    self.raw = raw
    self.dateLabel = dateLabel
    self.timeLabel = timeLabel
    self.detail = detail
  }
}

public struct OrgEditableInlineMarkupSet: Equatable, Sendable {
  public let rawText: String
  public let markups: [OrgEditableInlineMarkup]

  public init(rawText: String) {
    self.rawText = rawText
    self.markups = Self.parseMarkups(rawText)
  }

  public func replacing(
    markup: OrgEditableInlineMarkup,
    text: String? = nil,
    kind: OrgEditableInlineMarkup.Kind? = nil
  ) -> String {
    let nextKind = kind ?? markup.kind
    let normalizedText = text ?? markup.text
    guard !normalizedText.isEmpty else { return rawText }

    let marker = nextKind == markup.kind ? markup.marker : nextKind.defaultMarker
    return (rawText as NSString).replacingCharacters(
      in: NSRange(location: markup.startUTF16, length: markup.endUTF16 - markup.startUTF16),
      with: "\(marker)\(normalizedText)\(marker)"
    )
  }

  public static func wrappingSelection(
    in rawText: String,
    range: NSRange,
    kind: OrgEditableInlineMarkup.Kind
  ) -> OrgInlineSelectionEdit {
    let ns = rawText as NSString
    let location = min(max(0, range.location), ns.length)
    let length = min(max(0, range.length), ns.length - location)
    let safeRange = NSRange(location: location, length: length)
    let selectedText = ns.substring(with: safeRange)
    let replacementText = selectedText.isEmpty ? kind.placeholderText : selectedText
    let marker = kind.defaultMarker
    let wrappedText = "\(marker)\(replacementText)\(marker)"
    let updatedText = ns.replacingCharacters(in: safeRange, with: wrappedText)
    return OrgInlineSelectionEdit(
      text: updatedText,
      selectedRange: NSRange(
        location: location + (marker as NSString).length,
        length: (replacementText as NSString).length
      )
    )
  }

  private static func parseMarkups(_ raw: String) -> [OrgEditableInlineMarkup] {
    let ignoredRanges = ignoredInlineRanges(raw)
    var markups: [OrgEditableInlineMarkup] = []
    var cursor = raw.startIndex

    while cursor < raw.endIndex {
      var didParse = false
      for spec in delimiterSpecs where raw[cursor] == spec.marker {
        guard let parsed = parseDelimited(raw, at: cursor, marker: spec.marker),
              !spec.requiresOrgBoundary || markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close)
        else {
          continue
        }

        let rawRange = NSRange(
          location: cursor.utf16Offset(in: raw),
          length: parsed.end.utf16Offset(in: raw) - cursor.utf16Offset(in: raw)
        )
        guard !ignoredRanges.contains(where: { rangesOverlap(rawRange, $0) }) else {
          continue
        }

        markups.append(OrgEditableInlineMarkup(
          id: "markup:\(rawRange.location)",
          kind: spec.kind,
          marker: String(spec.marker),
          text: parsed.text,
          startUTF16: rawRange.location,
          endUTF16: rawRange.location + rawRange.length
        ))
        cursor = parsed.end
        didParse = true
        break
      }

      if !didParse {
        cursor = raw.index(after: cursor)
      }
    }

    return markups
  }

  private static func ignoredInlineRanges(_ raw: String) -> [NSRange] {
    let linkRanges = OrgEditableInlineLinkSet(rawText: raw).links.map(\.rawRange)
    let timestampRanges = OrgEditableInlineTimestampSet(rawText: raw).timestamps.map {
      NSRange(location: $0.startUTF16, length: $0.endUTF16 - $0.startUTF16)
    }
    return linkRanges + timestampRanges
  }

  private static func parseDelimited(
    _ raw: String,
    at cursor: String.Index,
    marker: Character
  ) -> (text: String, close: String.Index, end: String.Index)? {
    guard raw[cursor] == marker else { return nil }
    let contentStart = raw.index(after: cursor)
    guard contentStart < raw.endIndex, !raw[contentStart].isWhitespace else { return nil }

    var search = contentStart
    while search < raw.endIndex {
      guard let close = raw[search...].firstIndex(of: marker) else { return nil }
      let beforeClose = raw.index(before: close)
      let afterClose = raw.index(after: close)
      if !raw[beforeClose].isWhitespace {
        let text = String(raw[contentStart..<close])
        guard !text.isEmpty else { return nil }
        return (text, close, afterClose)
      }
      search = raw.index(after: close)
    }

    return nil
  }

  private static func markerLooksLikeOrgBoundary(_ raw: String, open: String.Index, close: String.Index) -> Bool {
    let beforeOpen = open > raw.startIndex ? raw.index(before: open) : nil
    let afterClose = raw.index(after: close)
    let opensAtBoundary = beforeOpen.map { isBoundary(raw[$0]) } ?? true
    let closesAtBoundary = afterClose < raw.endIndex ? isBoundary(raw[afterClose]) : true
    return opensAtBoundary && closesAtBoundary
  }

  private static func isBoundary(_ character: Character) -> Bool {
    if character.isWhitespace { return true }
    return !character.isASCIIWord
  }

  private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
  }

  private static let delimiterSpecs: [(marker: Character, kind: OrgEditableInlineMarkup.Kind, requiresOrgBoundary: Bool)] = [
    ("`", .code, false),
    ("~", .code, true),
    ("=", .code, true),
    ("*", .bold, true),
    ("/", .italic, true),
    ("_", .underline, true),
    ("+", .strike, true)
  ]
}

public struct OrgEditableInlineMarkup: Identifiable, Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case code
    case bold
    case italic
    case underline
    case strike

    var defaultMarker: String {
      switch self {
      case .code:
        return "`"
      case .bold:
        return "*"
      case .italic:
        return "/"
      case .underline:
        return "_"
      case .strike:
        return "+"
      }
    }

    var displayTitle: String {
      switch self {
      case .code:
        return "Code"
      case .bold:
        return "Bold"
      case .italic:
        return "Italic"
      case .underline:
        return "Underline"
      case .strike:
        return "Strike"
      }
    }

    var placeholderText: String {
      switch self {
      case .code:
        return "code"
      case .bold, .italic, .underline, .strike:
        return "text"
      }
    }
  }

  public let id: String
  public let kind: Kind
  public let marker: String
  public let text: String
  public let startUTF16: Int
  public let endUTF16: Int
}

public struct OrgInlineSelectionEdit: Equatable, Sendable {
  public let text: String
  public let selectedRange: NSRange
}

public enum OrgEditableInlineToken: Equatable, Sendable {
  public static let focusedScanUTF16Limit = 12_000
  public static let focusedFullParseUTF16Limit = 2_000
  public static let focusedLocalScanUTF16Radius = 1_024

  case link(OrgEditableInlineLink)
  case timestamp(OrgEditableInlineTimestamp)
  case markup(OrgEditableInlineMarkup)

  public var id: String {
    switch self {
    case .link(let link):
      return link.id
    case .timestamp(let timestamp):
      return timestamp.id
    case .markup(let markup):
      return markup.id
    }
  }

  public var range: NSRange {
    switch self {
    case .link(let link):
      return NSRange(location: link.startUTF16, length: link.endUTF16 - link.startUTF16)
    case .timestamp(let timestamp):
      return NSRange(location: timestamp.startUTF16, length: timestamp.endUTF16 - timestamp.startUTF16)
    case .markup(let markup):
      return NSRange(location: markup.startUTF16, length: markup.endUTF16 - markup.startUTF16)
    }
  }

  public static func focused(
    in rawText: String,
    selection: NSRange,
    maxUTF16Length: Int = focusedScanUTF16Limit
  ) -> OrgEditableInlineToken? {
    guard let textLength = boundedUTF16Length(in: rawText, maxUTF16Length: maxUTF16Length) else {
      return nil
    }

    let safeLocation = min(max(0, selection.location), textLength)
    let safeSelection = NSRange(
      location: safeLocation,
      length: min(max(0, selection.length), max(0, textLength - safeLocation))
    )
    guard hasFocusedInlineSyntaxCandidate(in: rawText, selection: safeSelection) else {
      return nil
    }

    if textLength > focusedFullParseUTF16Limit {
      return focusedInLocalWindow(rawText, selection: safeSelection, textLength: textLength)
    }

    let tokens = all(in: rawText)
    guard !tokens.isEmpty else { return nil }

    if safeSelection.length > 0 {
      return tokens.first { rangesOverlap($0.range, safeSelection) }
    }

    return tokens.first { token in
      let range = token.range
      return safeSelection.location >= range.location && safeSelection.location <= range.location + range.length
    }
  }

  public static func shouldScanFocusedToken(
    utf16Length: Int,
    maxUTF16Length: Int = focusedScanUTF16Limit
  ) -> Bool {
    maxUTF16Length >= 0 && utf16Length <= maxUTF16Length
  }

  public static func hasFocusedInlineSyntaxCandidate(in rawText: String, selection: NSRange) -> Bool {
    OrgInlineParser.hasInlineSyntaxCandidate(
      rawText,
      near: selection,
      radius: focusedLocalScanUTF16Radius
    )
  }

  public static func boundedUTF16Length(
    in text: String,
    maxUTF16Length: Int = focusedScanUTF16Limit
  ) -> Int? {
    guard maxUTF16Length >= 0 else { return nil }
    var count = 0
    for _ in text.utf16 {
      count += 1
      if count > maxUTF16Length {
        return nil
      }
    }
    return count
  }

  private static func focusedInLocalWindow(
    _ rawText: String,
    selection safeSelection: NSRange,
    textLength: Int
  ) -> OrgEditableInlineToken? {
    let localEnd = min(
      textLength,
      safeSelection.location + max(0, safeSelection.length) + focusedLocalScanUTF16Radius
    )
    guard let window = substringWindow(
      in: rawText,
      startUTF16: max(0, safeSelection.location - focusedLocalScanUTF16Radius),
      endUTF16: localEnd
    ) else {
      return nil
    }

    let localTokens = all(in: window.text).map { $0.shiftingUTF16Ranges(by: window.startUTF16) }
    guard !localTokens.isEmpty else { return nil }
    if safeSelection.length > 0 {
      return localTokens.first { rangesOverlap($0.range, safeSelection) }
    }
    return localTokens.first { token in
      let range = token.range
      return safeSelection.location >= range.location && safeSelection.location <= range.location + range.length
    }
  }

  private static func substringWindow(
    in text: String,
    startUTF16 requestedStart: Int,
    endUTF16 requestedEnd: Int
  ) -> (text: String, startUTF16: Int)? {
    let ns = text as NSString
    var start = min(max(0, requestedStart), ns.length)
    var end = min(max(start, requestedEnd), ns.length)

    while start >= 0 {
      while end <= ns.length {
        let range = NSRange(location: start, length: end - start)
        if let swiftRange = Range(range, in: text) {
          return (String(text[swiftRange]), start)
        }
        end += 1
      }
      start -= 1
      end = min(max(start, requestedEnd), ns.length)
    }
    return nil
  }

  private static func all(in rawText: String) -> [OrgEditableInlineToken] {
    let links = OrgEditableInlineLinkSet(rawText: rawText).links.map(OrgEditableInlineToken.link)
    let timestamps = OrgEditableInlineTimestampSet(rawText: rawText).timestamps.map(OrgEditableInlineToken.timestamp)
    let markups = OrgEditableInlineMarkupSet(rawText: rawText).markups.map(OrgEditableInlineToken.markup)
    return (links + timestamps + markups).sorted {
      if $0.range.location != $1.range.location {
        return $0.range.location < $1.range.location
      }
      return $0.range.length > $1.range.length
    }
  }

  private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
  }

  private func shiftingUTF16Ranges(by offset: Int) -> OrgEditableInlineToken {
    switch self {
    case .link(let link):
      return .link(OrgEditableInlineLink(
        id: "link:\(link.startUTF16 + offset)",
        kind: link.kind,
        label: link.label,
        target: link.target,
        startUTF16: link.startUTF16 + offset,
        endUTF16: link.endUTF16 + offset
      ))
    case .timestamp(let timestamp):
      return .timestamp(OrgEditableInlineTimestamp(
        id: "timestamp:\(timestamp.startUTF16 + offset)",
        date: timestamp.date,
        time: timestamp.time,
        detail: timestamp.detail,
        isActive: timestamp.isActive,
        startUTF16: timestamp.startUTF16 + offset,
        endUTF16: timestamp.endUTF16 + offset
      ))
    case .markup(let markup):
      return .markup(OrgEditableInlineMarkup(
        id: "markup:\(markup.startUTF16 + offset)",
        kind: markup.kind,
        marker: markup.marker,
        text: markup.text,
        startUTF16: markup.startUTF16 + offset,
        endUTF16: markup.endUTF16 + offset
      ))
    }
  }
}

public struct OrgEditableInlineLinkSet: Equatable, Sendable {
  public let rawText: String
  public let links: [OrgEditableInlineLink]

  public init(rawText: String) {
    self.rawText = rawText
    self.links = Self.parseLinks(rawText)
  }

  public func replacing(
    link: OrgEditableInlineLink,
    label: String? = nil,
    target: String? = nil
  ) -> String {
    let normalizedLabel = (label ?? link.label).trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTarget = (target ?? link.target).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTarget.isEmpty else { return rawText }

    let replacement = Self.formattedBracketLink(target: normalizedTarget, label: normalizedLabel)
    return (rawText as NSString).replacingCharacters(
      in: NSRange(location: link.startUTF16, length: link.endUTF16 - link.startUTF16),
      with: replacement
    )
  }

  private static func formattedBracketLink(target: String, label: String) -> String {
    guard !label.isEmpty, label != target else {
      return "[[\(target)]]"
    }
    return "[[\(target)][\(label)]]"
  }

  private static func parseLinks(_ raw: String) -> [OrgEditableInlineLink] {
    var links: [OrgEditableInlineLink] = []
    appendRegexLinks(
      pattern: #"\[\[([^\]\n]+)(?:\]\[([^\]\n]*))?\]\]"#,
      raw: raw,
      targetCapture: 1,
      labelCapture: 2,
      kind: .orgBracket,
      into: &links
    )
    appendRegexLinks(
      pattern: #"(?<!\[)\[([^\]\n]+)\]\(([^\)\n]+)\)"#,
      raw: raw,
      targetCapture: 2,
      labelCapture: 1,
      kind: .markdown,
      into: &links
    )
    appendRegexLinks(
      pattern: #"https?://[^\s\]\)"'`<>]+"#,
      raw: raw,
      targetCapture: 0,
      labelCapture: nil,
      kind: .plainURL,
      into: &links
    )
    appendRegexLinks(
      pattern: #"(?:(?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:[:#]\d+)?"#,
      raw: raw,
      targetCapture: 0,
      labelCapture: nil,
      kind: .fileReference,
      into: &links
    )

    return links.sorted {
      if $0.startUTF16 != $1.startUTF16 {
        return $0.startUTF16 < $1.startUTF16
      }
      return $0.endUTF16 < $1.endUTF16
    }
  }

  private static func appendRegexLinks(
    pattern: String,
    raw: String,
    targetCapture: Int,
    labelCapture: Int?,
    kind: OrgEditableInlineLink.Kind,
    into links: inout [OrgEditableInlineLink]
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    let ns = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
    for match in matches {
      let rawRange = match.range(at: 0)
      guard rawRange.location != NSNotFound,
            rawRange.length > 0,
            !links.contains(where: { rangesOverlap(rawRange, $0.rawRange) }),
            match.numberOfRanges > targetCapture,
            match.range(at: targetCapture).location != NSNotFound
      else {
        continue
      }

      var linkRange = rawRange
      var target = ns.substring(with: match.range(at: targetCapture))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      while let last = target.last, [".", ",", ";", ":"].contains(String(last)) {
        target.removeLast()
        if targetCapture == 0 {
          linkRange.length -= 1
        }
      }
      guard !target.isEmpty else { continue }

      let label: String
      if let labelCapture,
         match.numberOfRanges > labelCapture,
         match.range(at: labelCapture).location != NSNotFound {
        label = ns.substring(with: match.range(at: labelCapture))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      } else if kind == .fileReference,
                let reference = OpenClawFileReference.fromLinkTarget(target) {
        label = reference.displayTitle
      } else {
        label = target
      }

      links.append(OrgEditableInlineLink(
        id: "link:\(rawRange.location)",
        kind: kind,
        label: label.isEmpty ? target : label,
        target: target,
        startUTF16: linkRange.location,
        endUTF16: linkRange.location + linkRange.length
      ))
    }
  }

  private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
  }
}

public struct OrgEditableInlineLink: Identifiable, Equatable, Sendable {
  public enum Kind: String, Sendable {
    case orgBracket
    case markdown
    case plainURL
    case fileReference
  }

  public let id: String
  public let kind: Kind
  public let label: String
  public let target: String
  public let startUTF16: Int
  public let endUTF16: Int

  fileprivate var rawRange: NSRange {
    NSRange(location: startUTF16, length: endUTF16 - startUTF16)
  }
}

public struct OrgEditableInlineTimestampSet: Equatable, Sendable {
  public let rawText: String
  public let timestamps: [OrgEditableInlineTimestamp]

  public init(rawText: String) {
    self.rawText = rawText
    self.timestamps = Self.parseTimestamps(rawText)
  }

  public func replacing(
    timestamp: OrgEditableInlineTimestamp,
    date: String? = nil,
    time: String? = nil,
    detail: String? = nil,
    isActive: Bool? = nil
  ) -> String {
    let replacement = Self.formattedTimestamp(
      date: date ?? timestamp.date,
      time: time ?? timestamp.time,
      detail: detail ?? timestamp.detail,
      isActive: isActive ?? timestamp.isActive
    )
    return (rawText as NSString).replacingCharacters(
      in: NSRange(location: timestamp.startUTF16, length: timestamp.endUTF16 - timestamp.startUTF16),
      with: replacement
    )
  }

  private static func parseTimestamps(_ raw: String) -> [OrgEditableInlineTimestamp] {
    let pattern = #"([<\[])(\d{4}(?:-\d{0,2}(?:-\d{0,2})?)?)(?:\s+[A-Za-z]{3})?(?:\s+(\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?))?([^>\]]*)([>\]])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
    return matches.compactMap { match in
      guard match.numberOfRanges == 6,
            match.range(at: 1).location != NSNotFound,
            match.range(at: 2).location != NSNotFound,
            match.range(at: 5).location != NSNotFound
      else {
        return nil
      }

      let open = ns.substring(with: match.range(at: 1))
      let close = ns.substring(with: match.range(at: 5))
      guard (open == "<" && close == ">") || (open == "[" && close == "]") else {
        return nil
      }

      let rawRange = match.range(at: 0)
      let time = match.range(at: 3).location == NSNotFound
        ? ""
        : ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = match.range(at: 4).location == NSNotFound
        ? ""
        : ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespacesAndNewlines)

      return OrgEditableInlineTimestamp(
        id: "timestamp:\(rawRange.location)",
        date: ns.substring(with: match.range(at: 2)),
        time: time,
        detail: detail,
        isActive: open == "<",
        startUTF16: rawRange.location,
        endUTF16: rawRange.location + rawRange.length
      )
    }
  }

  private static func formattedTimestamp(date: String, time: String, detail: String, isActive: Bool) -> String {
    let normalizedDate = date.trimmingCharacters(in: .whitespacesAndNewlines)
    let timestampDate = normalizedDate.isEmpty ? "1970-01-01" : normalizedDate
    var parts = [timestampDate]
    if let weekday = weekdayLabel(for: timestampDate) {
      parts.append(weekday)
    }

    let normalizedTime = time.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedTime.isEmpty {
      parts.append(normalizedTime)
    }

    let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedDetail.isEmpty {
      parts.append(normalizedDetail)
    }

    let body = parts.joined(separator: " ")
    return isActive ? "<\(body)>" : "[\(body)]"
  }

  private static func weekdayLabel(for date: String) -> String? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let parsed = formatter.date(from: date) else { return nil }
    formatter.dateFormat = "EEE"
    return formatter.string(from: parsed)
  }
}

public struct OrgEditableInlineTimestamp: Identifiable, Equatable, Sendable {
  public let id: String
  public let date: String
  public let time: String
  public let detail: String
  public let isActive: Bool
  public let startUTF16: Int
  public let endUTF16: Int
}

public enum OrgInlineParser {
  public static func parse(_ raw: String, linkResolver: OrgRoamLinkResolver = .empty) -> [OrgInlineSpan] {
    guard hasInlineSyntaxCandidate(raw) else {
      return raw.isEmpty ? [] : [.text(raw)]
    }

    var spans: [OrgInlineSpan] = []
    var buffer = ""
    var cursor = raw.startIndex

    func flushText() {
      guard !buffer.isEmpty else { return }
      spans.append(.text(buffer))
      buffer = ""
    }

    while cursor < raw.endIndex {
      if let parsed = parseBracketLink(raw, at: cursor, linkResolver: linkResolver) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseMarkdownLink(raw, at: cursor, linkResolver: linkResolver) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parsePlainURL(raw, at: cursor) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseTimestamp(raw, at: cursor) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseFileReference(raw, at: cursor) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "`", kind: .code) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "~", kind: .code),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "=", kind: .code),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "*", kind: .bold),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "/", kind: .italic),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "_", kind: .underline),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "+", kind: .strike),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      buffer.append(raw[cursor])
      cursor = raw.index(after: cursor)
    }

    flushText()
    return coalesceText(spans)
  }

  public static func hasInlineSyntaxCandidate(_ raw: String) -> Bool {
    let bytes = raw.utf8
    var index = bytes.startIndex
    while index < bytes.endIndex {
      switch bytes[index] {
      case 0x5B, 0x5D, 0x3C, 0x3E, 0x60, 0x7E, 0x3D, 0x2A, 0x2F, 0x5F, 0x2B:
        return true
      case 0x2E:
        if utf8(bytes, at: index, matches: orgExtensionBytes)
          || utf8(bytes, at: index, matches: mdExtensionBytes) {
          return true
        }
      case 0x68, 0x48:
        if utf8(bytes, at: index, matches: httpBytes)
          || utf8(bytes, at: index, matches: httpsBytes)
          || utf8(bytes, at: index, matches: uppercaseHTTPBytes)
          || utf8(bytes, at: index, matches: uppercaseHTTPSBytes) {
          return true
        }
      default:
        break
      }
      index = bytes.index(after: index)
    }
    return false
  }

  public static func hasInlineSyntaxCandidate(
    _ raw: String,
    near range: NSRange,
    radius: Int
  ) -> Bool {
    guard !raw.isEmpty else { return false }
    let text = raw as NSString
    let safeRadius = max(0, radius)
    let textLength = text.length
    let safeLocation = min(max(0, range.location), textLength)
    let selectionEnd = min(textLength, safeLocation + min(max(0, range.length), textLength - safeLocation))
    return hasInlineSyntaxCandidate(
      text,
      startUTF16: max(0, safeLocation - safeRadius),
      endUTF16: min(textLength, selectionEnd + safeRadius)
    )
  }

  private enum DelimitedKind {
    case code
    case bold
    case italic
    case underline
    case strike
  }

  private static func parseBracketLink(
    _ raw: String,
    at cursor: String.Index,
    linkResolver: OrgRoamLinkResolver
  ) -> (span: OrgInlineSpan, end: String.Index)? {
    guard raw[cursor...].hasPrefix("[[") else { return nil }
    let bodyStart = raw.index(cursor, offsetBy: 2)
    guard let closeRange = raw[bodyStart...].range(of: "]]") else { return nil }
    let body = String(raw[bodyStart..<closeRange.lowerBound])
    let parts = body.components(separatedBy: "][")
    guard let target = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
      return nil
    }
    let label = parts.dropFirst().joined(separator: "][").trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = OpenClawFileReference.fromLinkTarget(target).map {
      OrgRoamResolvedLink(title: $0.displayTitle, fileReference: $0)
    } ?? linkResolver.resolve(target: target)
    let display: String
    if !label.isEmpty {
      display = label
    } else if target.lowercased().hasPrefix("id:") {
      display = resolved?.title ?? target
    } else {
      display = target
    }
    return (
      .link(label: display, target: target, fileReference: resolved?.fileReference),
      closeRange.upperBound
    )
  }

  private static func parseMarkdownLink(
    _ raw: String,
    at cursor: String.Index,
    linkResolver: OrgRoamLinkResolver
  ) -> (span: OrgInlineSpan, end: String.Index)? {
    guard raw[cursor] == "[", !raw[cursor...].hasPrefix("[[") else { return nil }
    let labelStart = raw.index(after: cursor)
    guard let labelEnd = raw[labelStart...].firstIndex(of: "]") else { return nil }
    let targetOpen = raw.index(after: labelEnd)
    guard targetOpen < raw.endIndex, raw[targetOpen] == "(" else { return nil }
    let targetStart = raw.index(after: targetOpen)
    guard let targetEnd = raw[targetStart...].firstIndex(of: ")") else { return nil }
    let label = String(raw[labelStart..<labelEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    let target = String(raw[targetStart..<targetEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, !target.isEmpty else { return nil }
    let resolved = OpenClawFileReference.fromLinkTarget(target).map {
      OrgRoamResolvedLink(title: $0.displayTitle, fileReference: $0)
    } ?? linkResolver.resolve(target: target)
    return (
      .link(label: label, target: target, fileReference: resolved?.fileReference),
      raw.index(after: targetEnd)
    )
  }

  private static func parsePlainURL(_ raw: String, at cursor: String.Index) -> (span: OrgInlineSpan, end: String.Index)? {
    guard raw[cursor...].hasPrefix("http://") || raw[cursor...].hasPrefix("https://") else { return nil }
    var end = cursor
    while end < raw.endIndex, !raw[end].isWhitespace, !["]", ")", "\"", "'", "`", "<", ">"].contains(raw[end]) {
      end = raw.index(after: end)
    }
    var target = String(raw[cursor..<end])
    while let last = target.last, [".", ",", ";", ":"].contains(String(last)) {
      target.removeLast()
      end = raw.index(before: end)
    }
    guard !target.isEmpty else { return nil }
    return (.link(label: target, target: target, fileReference: nil), end)
  }

  private static func parseTimestamp(_ raw: String, at cursor: String.Index) -> (span: OrgInlineSpan, end: String.Index)? {
    let open = raw[cursor]
    guard open == "<" || open == "[" else { return nil }
    let close: Character = open == "<" ? ">" : "]"
    let bodyStart = raw.index(after: cursor)
    guard let closeIndex = raw[bodyStart...].firstIndex(of: close) else { return nil }
    let body = String(raw[bodyStart..<closeIndex])
    guard let parsed = parseTimestampBody(body) else { return nil }
    return (
      .timestamp(OrgInlineTimestamp(
        raw: String(raw[cursor...closeIndex]),
        dateLabel: parsed.dateLabel,
        timeLabel: parsed.timeLabel,
        detail: parsed.detail
      )),
      raw.index(after: closeIndex)
    )
  }

  private static func parseTimestampBody(_ body: String) -> (dateLabel: String, timeLabel: String?, detail: String?)? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let ns = trimmed as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    guard let match = timestampBodyRegex.firstMatch(in: trimmed, range: fullRange),
          match.range.location == 0,
          match.range(at: 1).location != NSNotFound
    else {
      return nil
    }

    let rawDate = ns.substring(with: match.range(at: 1))
    let timeLabel: String?
    if match.range(at: 2).location != NSNotFound {
      timeLabel = ns.substring(with: match.range(at: 2))
    } else {
      timeLabel = nil
    }
    let detail: String?
    if match.range(at: 3).location != NSNotFound {
      let parsedDetail = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
      detail = parsedDetail.isEmpty ? nil : parsedDetail
    } else {
      detail = nil
    }

    return (formattedDate(rawDate), timeLabel, detail)
  }

  private static func formattedDate(_ raw: String) -> String {
    let parts = raw.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          parts[1] >= 1,
          parts[1] <= monthNames.count
    else {
      return raw
    }
    return "\(monthNames[parts[1] - 1]) \(parts[2]), \(parts[0])"
  }

  private static func parseFileReference(_ raw: String, at cursor: String.Index) -> (span: OrgInlineSpan, end: String.Index)? {
    guard mayStartFileReference(raw, at: cursor) else { return nil }
    let remaining = String(raw[cursor...])
    let nsRemaining = remaining as NSString
    let fullRange = NSRange(location: 0, length: nsRemaining.length)
    guard let match = fileReferenceRegex.firstMatch(in: remaining, range: fullRange),
          match.range.location == 0
    else {
      return nil
    }

    let rawPath = nsRemaining.substring(with: match.range(at: 1))
    let line: Int?
    if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
      line = Int(nsRemaining.substring(with: match.range(at: 2)))
    } else {
      line = nil
    }
    let reference = OpenClawFileReference(path: rawPath, line: line)
    let display = reference.displayTitle
    let end = raw.index(cursor, offsetBy: match.range.length)
    return (.link(label: display, target: reference.path, fileReference: reference), end)
  }

  private static func mayStartFileReference(_ raw: String, at cursor: String.Index) -> Bool {
    let character = raw[cursor]
    if character == "/" || character == "~" {
      return true
    }
    if raw[cursor...].hasPrefix("file:") {
      return true
    }
    guard character.isASCIIWord || character == "." || character == "-" || character == "_" else {
      return false
    }

    var hasSlash = false
    var search = cursor
    while search < raw.endIndex {
      let current = raw[search]
      if current.isWhitespace || ["]", ")", "\"", "'", "`", "<", ">"].contains(current) {
        break
      }
      if current == "/" {
        hasSlash = true
      }
      if hasSlash,
         raw[search...].hasPrefix(".org") || raw[search...].hasPrefix(".md") {
        return true
      }
      search = raw.index(after: search)
    }
    return false
  }

  private static func parseDelimited(
    _ raw: String,
    at cursor: String.Index,
    marker: Character,
    kind: DelimitedKind
  ) -> (span: OrgInlineSpan, close: String.Index, end: String.Index)? {
    guard raw[cursor] == marker else { return nil }
    let contentStart = raw.index(after: cursor)
    guard contentStart < raw.endIndex, !raw[contentStart].isWhitespace else { return nil }

    var search = contentStart
    while search < raw.endIndex {
      guard let close = raw[search...].firstIndex(of: marker) else { return nil }
      let beforeClose = raw.index(before: close)
      let afterClose = raw.index(after: close)
      if !raw[beforeClose].isWhitespace {
        let content = String(raw[contentStart..<close])
        guard !content.isEmpty else { return nil }
        return (span(for: kind, content: content), close, afterClose)
      }
      search = raw.index(after: close)
    }

    return nil
  }

  private static func markerLooksLikeOrgBoundary(_ raw: String, open: String.Index, close: String.Index) -> Bool {
    let beforeOpen = open > raw.startIndex ? raw.index(before: open) : nil
    let afterClose = raw.index(after: close)
    let opensAtBoundary = beforeOpen.map { isBoundary(raw[$0]) } ?? true
    let closesAtBoundary = afterClose < raw.endIndex ? isBoundary(raw[afterClose]) : true
    return opensAtBoundary && closesAtBoundary
  }

  private static func isBoundary(_ character: Character) -> Bool {
    if character.isWhitespace { return true }
    return !character.isASCIIWord
  }

  private static func span(for kind: DelimitedKind, content: String) -> OrgInlineSpan {
    switch kind {
    case .code:
      return .code(content)
    case .bold:
      return .bold(content)
    case .italic:
      return .italic(content)
    case .underline:
      return .underline(content)
    case .strike:
      return .strike(content)
    }
  }

  private static func coalesceText(_ spans: [OrgInlineSpan]) -> [OrgInlineSpan] {
    var output: [OrgInlineSpan] = []
    for span in spans {
      if case .text(let next) = span,
         case .text(let previous)? = output.last {
        output.removeLast()
        output.append(.text(previous + next))
      } else {
        output.append(span)
      }
    }
    return output
  }

  private static let monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
  ]
  private static let orgExtensionBytes: [UInt8] = [0x2E, 0x6F, 0x72, 0x67]
  private static let mdExtensionBytes: [UInt8] = [0x2E, 0x6D, 0x64]
  private static let httpBytes: [UInt8] = [0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F, 0x2F]
  private static let httpsBytes: [UInt8] = [0x68, 0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F]
  private static let uppercaseHTTPBytes: [UInt8] = [0x48, 0x54, 0x54, 0x50, 0x3A, 0x2F, 0x2F]
  private static let uppercaseHTTPSBytes: [UInt8] = [0x48, 0x54, 0x54, 0x50, 0x53, 0x3A, 0x2F, 0x2F]
  private static let orgExtensionUTF16: [UInt16] = [0x2E, 0x6F, 0x72, 0x67]
  private static let mdExtensionUTF16: [UInt16] = [0x2E, 0x6D, 0x64]
  private static let httpUTF16: [UInt16] = [0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F, 0x2F]
  private static let httpsUTF16: [UInt16] = [0x68, 0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F]
  private static let uppercaseHTTPUTF16: [UInt16] = [0x48, 0x54, 0x54, 0x50, 0x3A, 0x2F, 0x2F]
  private static let uppercaseHTTPSUTF16: [UInt16] = [0x48, 0x54, 0x54, 0x50, 0x53, 0x3A, 0x2F, 0x2F]

  private static func utf8(_ bytes: String.UTF8View, at start: String.UTF8View.Index, matches pattern: [UInt8]) -> Bool {
    var index = start
    for expected in pattern {
      guard index < bytes.endIndex, bytes[index] == expected else {
        return false
      }
      index = bytes.index(after: index)
    }
    return true
  }

  private static func hasInlineSyntaxCandidate(
    _ text: NSString,
    startUTF16: Int,
    endUTF16: Int
  ) -> Bool {
    let safeStart = min(max(0, startUTF16), text.length)
    let safeEnd = min(max(safeStart, endUTF16), text.length)
    guard safeStart < safeEnd else {
      return false
    }

    var index = safeStart
    let end = safeEnd
    while index < end {
      switch text.character(at: index) {
      case 0x5B, 0x5D, 0x3C, 0x3E, 0x60, 0x7E, 0x3D, 0x2A, 0x2F, 0x5F, 0x2B:
        return true
      case 0x2E:
        if utf16Matches(text, at: index, before: end, pattern: orgExtensionUTF16)
          || utf16Matches(text, at: index, before: end, pattern: mdExtensionUTF16) {
          return true
        }
      case 0x68, 0x48:
        if utf16Matches(text, at: index, before: end, pattern: httpUTF16)
          || utf16Matches(text, at: index, before: end, pattern: httpsUTF16)
          || utf16Matches(text, at: index, before: end, pattern: uppercaseHTTPUTF16)
          || utf16Matches(text, at: index, before: end, pattern: uppercaseHTTPSUTF16) {
          return true
        }
      default:
        break
      }
      index += 1
    }
    return false
  }

  private static func utf16Matches(
    _ text: NSString,
    at start: Int,
    before end: Int,
    pattern: [UInt16]
  ) -> Bool {
    var index = start
    for expected in pattern {
      guard index < end, text.character(at: index) == expected else {
        return false
      }
      index += 1
    }
    return true
  }

  private static let timestampBodyRegex = try! NSRegularExpression(
    pattern: #"^(\d{4}-\d{2}-\d{2})(?:\s+[A-Za-z]{3})?(?:\s+(\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?))?(.*)$"#
  )
  private static let fileReferenceRegex = try! NSRegularExpression(
    pattern: #"^((?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:(?::|#)[Ll]?(\d+)(?:-[Ll]?\d+)?)?"#
  )
}

public struct OrgMediaAttachment: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case image
    case video
  }

  public struct EmbeddedGroup: Equatable, Sendable {
    public let displayText: String
    public let attachments: [OrgMediaAttachment]
  }

  public let kind: Kind
  public let label: String
  public let target: String
  public let resolvedPath: String?

  public var remoteURL: URL? {
    Self.remoteURL(forTarget: target)
  }

  public var isRemote: Bool {
    remoteURL != nil
  }

  public var resolvedURL: URL? {
    if let remoteURL {
      return remoteURL
    }
    return resolvedPath.map { URL(fileURLWithPath: $0) }
  }

  public var displayName: String {
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedLabel.isEmpty {
      return trimmedLabel
    }
    let cleaned = Self.cleanTarget(target)
    if let url = Self.remoteURL(forTarget: cleaned) {
      let pathName = url.lastPathComponent
      if !pathName.isEmpty {
        return pathName
      }
      return url.host ?? target
    }
    let name = URL(fileURLWithPath: cleaned).lastPathComponent
    return name.isEmpty ? target : name
  }

  public static func standalone(
    raw: String,
    sourceFile: String? = nil,
    corpusRoot: URL? = nil
  ) -> OrgMediaAttachment? {
    guard mayContainStandaloneMedia(raw) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
    guard let link = standaloneLink(trimmed) else { return nil }
    guard let kind = kind(forTarget: link.target) else { return nil }

    return OrgMediaAttachment(
      kind: kind,
      label: link.label,
      target: link.target,
      resolvedPath: remoteURL(forTarget: link.target) == nil
        ? resolvePath(link.target, sourceFile: sourceFile, corpusRoot: corpusRoot)
        : nil
    )
  }

  public static func embedded(
    in raw: String,
    sourceFile: String? = nil,
    corpusRoot: URL? = nil
  ) -> EmbeddedGroup? {
    guard mayContainMediaTarget(raw) else { return nil }

    var cursor = raw.startIndex
    var displayText = ""
    var attachments: [OrgMediaAttachment] = []

    while cursor < raw.endIndex {
      if let parsed = parseEmbeddedBracketLink(raw, at: cursor, sourceFile: sourceFile, corpusRoot: corpusRoot) {
        attachments.append(parsed.attachment)
        cursor = parsed.end
        continue
      }

      if let parsed = parseEmbeddedMarkdownLink(raw, at: cursor, sourceFile: sourceFile, corpusRoot: corpusRoot) {
        attachments.append(parsed.attachment)
        cursor = parsed.end
        continue
      }

      if let parsed = parseEmbeddedPlainMediaURL(raw, at: cursor, sourceFile: sourceFile, corpusRoot: corpusRoot) {
        attachments.append(parsed.attachment)
        cursor = parsed.end
        continue
      }

      displayText.append(raw[cursor])
      cursor = raw.index(after: cursor)
    }

    guard !attachments.isEmpty else { return nil }
    return EmbeddedGroup(displayText: normalizedEmbeddedDisplayText(displayText), attachments: attachments)
  }

  public static func mayContainStandaloneMedia(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
    if let link = standaloneLink(trimmed),
       kind(forTarget: link.target) != nil {
      return true
    }
    guard let dot = trimmed.lastIndex(of: ".") else { return false }

    let extensionStart = trimmed.index(after: dot)
    guard extensionStart < trimmed.endIndex else { return false }
    let extensionEnd = trimmed[extensionStart...].firstIndex { character in
      character == "]" || character == ")" || character == "#" || character == "?" || character.isWhitespace
    } ?? trimmed.endIndex
    let ext = String(trimmed[extensionStart..<extensionEnd]).lowercased()
    guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else {
      return false
    }

    if trimmed.hasPrefix("[[") || trimmed.hasPrefix("[") {
      return true
    }
    return trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
  }

  public static func mayContainMediaTarget(_ raw: String) -> Bool {
    let lowercased = raw.lowercased()
    if lowercased.contains("youtube.com")
      || lowercased.contains("youtu.be")
      || lowercased.contains("vimeo.com") {
      return true
    }

    for ext in imageExtensions.union(videoExtensions) {
      if lowercased.contains(".\(ext)") {
        return true
      }
    }
    return false
  }

  private static func standaloneLink(_ raw: String) -> (label: String, target: String)? {
    if let bracket = parseBracketLink(raw) {
      return bracket
    }
    if let markdown = parseMarkdownLink(raw) {
      return markdown
    }
    guard raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
    return (label: "", target: raw)
  }

  private static func parseBracketLink(_ raw: String) -> (label: String, target: String)? {
    let pattern = #"^\[\[([^\]\n]+)(?:\]\[([^\]\n]*))?\]\]$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = raw as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: raw, range: range),
          match.range(at: 1).location != NSNotFound
    else {
      return nil
    }
    let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    let label = match.range(at: 2).location == NSNotFound
      ? ""
      : ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }
    return (label, target)
  }

  private static func parseMarkdownLink(_ raw: String) -> (label: String, target: String)? {
    let pattern = #"^\[([^\]\n]*)\]\(([^\)\n]+)\)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = raw as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: raw, range: range),
          match.range(at: 2).location != NSNotFound
    else {
      return nil
    }
    let label = match.range(at: 1).location == NSNotFound
      ? ""
      : ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    let target = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }
    return (label, target)
  }

  private static func parseEmbeddedBracketLink(
    _ raw: String,
    at cursor: String.Index,
    sourceFile: String?,
    corpusRoot: URL?
  ) -> (attachment: OrgMediaAttachment, end: String.Index)? {
    guard raw[cursor...].hasPrefix("[[") else { return nil }
    let bodyStart = raw.index(cursor, offsetBy: 2)
    guard let closeRange = raw[bodyStart...].range(of: "]]") else { return nil }
    let linkRaw = String(raw[cursor..<closeRange.upperBound])
    guard let link = parseBracketLink(linkRaw),
          let attachment = attachment(label: link.label, target: link.target, sourceFile: sourceFile, corpusRoot: corpusRoot)
    else {
      return nil
    }
    return (attachment, closeRange.upperBound)
  }

  private static func parseEmbeddedMarkdownLink(
    _ raw: String,
    at cursor: String.Index,
    sourceFile: String?,
    corpusRoot: URL?
  ) -> (attachment: OrgMediaAttachment, end: String.Index)? {
    guard raw[cursor] == "[", !raw[cursor...].hasPrefix("[[") else { return nil }
    let labelStart = raw.index(after: cursor)
    guard let labelEnd = raw[labelStart...].firstIndex(of: "]") else { return nil }
    let targetOpen = raw.index(after: labelEnd)
    guard targetOpen < raw.endIndex, raw[targetOpen] == "(" else { return nil }
    let targetStart = raw.index(after: targetOpen)
    guard let targetEnd = raw[targetStart...].firstIndex(of: ")") else { return nil }
    let linkRaw = String(raw[cursor...targetEnd])
    guard let link = parseMarkdownLink(linkRaw),
          let attachment = attachment(label: link.label, target: link.target, sourceFile: sourceFile, corpusRoot: corpusRoot)
    else {
      return nil
    }
    return (attachment, raw.index(after: targetEnd))
  }

  private static func parseEmbeddedPlainMediaURL(
    _ raw: String,
    at cursor: String.Index,
    sourceFile: String?,
    corpusRoot: URL?
  ) -> (attachment: OrgMediaAttachment, end: String.Index)? {
    guard raw[cursor...].hasPrefix("http://") || raw[cursor...].hasPrefix("https://") else { return nil }
    var end = cursor
    while end < raw.endIndex, !raw[end].isWhitespace, !["]", ")", "\"", "'", "`", "<", ">"].contains(raw[end]) {
      end = raw.index(after: end)
    }

    var target = String(raw[cursor..<end])
    while let last = target.last, [".", ",", ";", ":"].contains(last) {
      target.removeLast()
      end = raw.index(before: end)
    }

    guard let attachment = attachment(label: "", target: target, sourceFile: sourceFile, corpusRoot: corpusRoot) else {
      return nil
    }
    return (attachment, end)
  }

  private static func attachment(
    label: String,
    target: String,
    sourceFile: String?,
    corpusRoot: URL?
  ) -> OrgMediaAttachment? {
    guard let kind = kind(forTarget: target) else { return nil }
    return OrgMediaAttachment(
      kind: kind,
      label: label,
      target: target,
      resolvedPath: remoteURL(forTarget: target) == nil
        ? resolvePath(target, sourceFile: sourceFile, corpusRoot: corpusRoot)
        : nil
    )
  }

  private static func normalizedEmbeddedDisplayText(_ raw: String) -> String {
    raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        String(line)
          .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
          .trimmingCharacters(in: .whitespaces)
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func kind(forTarget target: String) -> Kind? {
    let cleaned = cleanTarget(target)
    if isKnownVideoPageURL(cleaned) {
      return .video
    }
    let ext: String
    if let remoteURL = remoteURL(forTarget: cleaned) {
      ext = remoteURL.pathExtension.lowercased()
    } else {
      ext = URL(fileURLWithPath: cleaned).pathExtension.lowercased()
    }
    if imageExtensions.contains(ext) { return .image }
    if videoExtensions.contains(ext) { return .video }
    return nil
  }

  private static func resolvePath(_ target: String, sourceFile: String?, corpusRoot: URL?) -> String? {
    let cleaned = cleanTarget(target)
    guard !cleaned.isEmpty else { return nil }

    var candidates: [String] = []
    if cleaned.hasPrefix("~/") {
      candidates.append(NSHomeDirectory() + "/" + String(cleaned.dropFirst(2)))
    } else if NSString(string: cleaned).isAbsolutePath {
      candidates.append(cleaned)
    } else {
      if let sourceFile {
        candidates.append(URL(fileURLWithPath: sourceFile).deletingLastPathComponent().appendingPathComponent(cleaned).path)
      }
      if let corpusRoot {
        candidates.append(corpusRoot.appendingPathComponent(cleaned).standardizedFileURL.path)
      }
    }

    for candidate in candidates {
      let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
      if FileManager.default.fileExists(atPath: standardized) {
        return standardized
      }
    }
    return nil
  }

  private static func cleanTarget(_ target: String) -> String {
    var cleaned = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("file://") {
      cleaned = String(cleaned.dropFirst("file://".count))
    } else if cleaned.hasPrefix("file:") {
      cleaned = String(cleaned.dropFirst("file:".count))
    }
    if let fragment = cleaned.firstIndex(of: "#") {
      cleaned = String(cleaned[..<fragment])
    }
    return cleaned.removingPercentEncoding ?? cleaned
  }

  public static func remoteURL(forTarget target: String) -> URL? {
    let cleaned = cleanTarget(target)
    guard let url = URL(string: cleaned),
          let scheme = url.scheme?.lowercased()
    else {
      return nil
    }
    return scheme == "http" || scheme == "https" ? url : nil
  }

  private static func isKnownVideoPageURL(_ target: String) -> Bool {
    guard let url = remoteURL(forTarget: target),
          let host = url.host?.lowercased()
    else {
      return false
    }
    return host == "youtu.be"
      || host.hasSuffix(".youtube.com")
      || host == "youtube.com"
      || host.hasSuffix(".vimeo.com")
      || host == "vimeo.com"
  }

  private static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp"])
  private static let videoExtensions = Set(["mov", "mp4", "m4v", "avi", "webm"])
}

public struct OrgEditableMediaLink: Equatable, Sendable {
  public var kind: OrgMediaAttachment.Kind
  public var target: String
  public var label: String

  public init(kind: OrgMediaAttachment.Kind, target: String, label: String = "") {
    self.kind = kind
    self.target = target
    self.label = label
  }

  public init?(rawText: String) {
    guard let attachment = OrgMediaAttachment.standalone(raw: rawText) else {
      return nil
    }
    self.kind = attachment.kind
    self.target = attachment.target
    self.label = attachment.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? attachment.displayName
      : attachment.label
  }

  public var formattedRawText: String {
    let target = normalizedTarget
    let label = normalizedLabel
    return "[[\(target)][\(label)]]"
  }

  public var normalizedTarget: String {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = kind == .image ? "images/image.png" : "videos/video.mp4"
    let rawTarget = trimmed.isEmpty ? fallback : trimmed
    if let remoteURL = OrgMediaAttachment.remoteURL(forTarget: rawTarget) {
      return remoteURL.absoluteString
    }
    return rawTarget.lowercased().hasPrefix("file:")
      ? rawTarget
      : "file:\(rawTarget)"
  }

  private var normalizedLabel: String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return trimmed
    }
    return fallbackLabel(for: normalizedTarget)
  }

  private func fallbackLabel(for target: String) -> String {
    var cleaned = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("file://") {
      cleaned = String(cleaned.dropFirst("file://".count))
    } else if cleaned.hasPrefix("file:") {
      cleaned = String(cleaned.dropFirst("file:".count))
    }
    if let fragment = cleaned.firstIndex(of: "#") {
      cleaned = String(cleaned[..<fragment])
    }
    cleaned = cleaned.removingPercentEncoding ?? cleaned
    if let url = OrgMediaAttachment.remoteURL(forTarget: cleaned) {
      let filename = url.lastPathComponent
      if !filename.isEmpty {
        return filename
      }
      return url.host ?? (kind == .image ? "Image" : "Video")
    }
    let filename = URL(fileURLWithPath: cleaned).lastPathComponent
    if !filename.isEmpty {
      return filename
    }
    return kind == .image ? "Image" : "Video"
  }
}

public struct SourceBlockRunPlan: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let scriptExtension: String
  public let label: String

  public var commandLabel: String {
    ([label] + arguments).joined(separator: " ")
  }

  public static func plan(for language: String?) -> SourceBlockRunPlan? {
    let normalized = language?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""

    switch normalized {
    case "sh", "shell":
      return SourceBlockRunPlan(executable: "/bin/sh", arguments: [], scriptExtension: "sh", label: "sh")
    case "bash":
      return SourceBlockRunPlan(executable: "/bin/bash", arguments: [], scriptExtension: "sh", label: "bash")
    case "zsh":
      return SourceBlockRunPlan(executable: "/bin/zsh", arguments: [], scriptExtension: "zsh", label: "zsh")
    case "python", "python3", "py":
      return SourceBlockRunPlan(executable: "/usr/bin/env", arguments: ["python3"], scriptExtension: "py", label: "python3")
    case "javascript", "js", "node":
      return SourceBlockRunPlan(executable: "/usr/bin/env", arguments: ["node"], scriptExtension: "mjs", label: "node")
    case "ruby", "rb":
      return SourceBlockRunPlan(executable: "/usr/bin/env", arguments: ["ruby"], scriptExtension: "rb", label: "ruby")
    default:
      return nil
    }
  }
}

public enum SourceBlockRunStatus: Equatable, Sendable {
  case running
  case succeeded
  case failed
  case timedOut
  case unsupported
}

public struct SourceBlockRunState: Equatable, Sendable {
  public let status: SourceBlockRunStatus
  public let language: String
  public let commandLabel: String
  public let startedAt: Date?
  public let finishedAt: Date?
  public let duration: TimeInterval?
  public let exitCode: Int32?
  public let stdout: String
  public let stderr: String
  public let message: String?

  public init(
    status: SourceBlockRunStatus,
    language: String,
    commandLabel: String,
    startedAt: Date? = nil,
    finishedAt: Date? = nil,
    duration: TimeInterval? = nil,
    exitCode: Int32? = nil,
    stdout: String = "",
    stderr: String = "",
    message: String? = nil
  ) {
    self.status = status
    self.language = language
    self.commandLabel = commandLabel
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.duration = duration
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.message = message
  }
}

public enum SourceRunOutputPresentation: Equatable, Sendable {
  case text(String)
  case table(SourceRunTable)
  case bars([SourceRunBar])
  case line(SourceRunLineChart)

  public static func make(from raw: String) -> SourceRunOutputPresentation {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .text(raw) }

    if let json = jsonPresentation(trimmed) {
      return json
    }
    if let table = pipeTablePresentation(trimmed) {
      if let line = lineChart(from: table) {
        return .line(line)
      }
      return .table(table)
    }
    if let table = separatedTablePresentation(trimmed, delimiter: "\t") {
      if let line = lineChart(from: table) {
        return .line(line)
      }
      return .table(table)
    }
    if let table = separatedTablePresentation(trimmed, delimiter: ",") {
      if let line = lineChart(from: table) {
        return .line(line)
      }
      return .table(table)
    }
    return .text(raw)
  }

  private static func jsonPresentation(_ raw: String) -> SourceRunOutputPresentation? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data)
    else {
      return nil
    }

    if let dictionary = object as? [String: Any] {
      if let bars = numericBars(from: dictionary), !bars.isEmpty {
        return .bars(bars)
      }
      return .table(SourceRunTable(
        columns: ["Key", "Value"],
        rows: dictionary.keys.sorted().map { key in [key, stringValue(dictionary[key] ?? "")] }
      ))
    }

    if let rows = object as? [[String: Any]], !rows.isEmpty {
      let columns = Array(Set(rows.flatMap(\.keys))).sorted()
      let table = SourceRunTable(
        columns: columns,
        rows: rows.map { row in columns.map { stringValue(row[$0] ?? "") } }
      )
      if let line = lineChart(from: table) {
        return .line(line)
      }
      if let bars = rowBars(from: rows, columns: columns), !bars.isEmpty {
        return .bars(bars)
      }
      return .table(table)
    }

    if let values = object as? [Any], !values.isEmpty {
      return .table(SourceRunTable(
        columns: ["Value"],
        rows: values.map { [stringValue($0)] }
      ))
    }

    return nil
  }

  private static func pipeTablePresentation(_ raw: String) -> SourceRunTable? {
    let lines = raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && $0.hasPrefix("|") && $0.hasSuffix("|") }
    guard lines.count >= 2 else { return nil }

    var parsedRows: [[String]] = []
    for line in lines {
      var inner = line
      inner.removeFirst()
      inner.removeLast()
      let separatorBody = inner.trimmingCharacters(in: .whitespaces)
      if !separatorBody.isEmpty && separatorBody.allSatisfy({ $0 == "-" || $0 == "+" }) {
        continue
      }
      parsedRows.append(inner.split(separator: "|", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .whitespaces)
      })
    }

    guard let header = parsedRows.first,
          header.count >= 2,
          parsedRows.dropFirst().allSatisfy({ $0.count == header.count })
    else {
      return nil
    }
    return SourceRunTable(columns: header, rows: Array(parsedRows.dropFirst()))
  }

  private static func separatedTablePresentation(_ raw: String, delimiter: Character) -> SourceRunTable? {
    let lines = raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard lines.count >= 2 else { return nil }

    let parsed = lines.map { line in
      line.split(separator: delimiter, omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .whitespaces)
      }
    }
    guard let header = parsed.first,
          header.count >= 2,
          parsed.dropFirst().allSatisfy({ $0.count == header.count })
    else {
      return nil
    }
    return SourceRunTable(columns: header, rows: Array(parsed.dropFirst()))
  }

  private static func numericBars(from dictionary: [String: Any]) -> [SourceRunBar]? {
    let bars = dictionary.keys.sorted().compactMap { key -> SourceRunBar? in
      guard let value = numericValue(dictionary[key] ?? "") else { return nil }
      return SourceRunBar(label: key, value: value)
    }
    return bars.count == dictionary.count ? bars : nil
  }

  private static func rowBars(from rows: [[String: Any]], columns: [String]) -> [SourceRunBar]? {
    guard columns.count == 2 else { return nil }
    let numericColumns = columns.filter { column in
      rows.allSatisfy { numericValue($0[column] ?? "") != nil }
    }
    guard numericColumns.count == 1,
          let numericColumn = numericColumns.first,
          let labelColumn = columns.first(where: { $0 != numericColumn })
    else {
      return nil
    }

    var bars: [SourceRunBar] = []
    var seenLabels: [String: Int] = [:]
    for row in rows {
      guard let value = numericValue(row[numericColumn] ?? "") else { return nil }
      let baseLabel = stringValue(row[labelColumn] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !baseLabel.isEmpty else { return nil }

      let count = (seenLabels[baseLabel] ?? 0) + 1
      seenLabels[baseLabel] = count
      let label = count == 1 ? baseLabel : "\(baseLabel) \(count)"
      bars.append(SourceRunBar(label: label, value: value))
    }
    return bars
  }

  private static func lineChart(from table: SourceRunTable) -> SourceRunLineChart? {
    guard table.columns.count == 2,
          table.rows.count >= 2
    else {
      return nil
    }

    var points: [SourceRunLinePoint] = []
    for row in table.rows {
      guard row.count == 2,
            let x = numericValue(row[0]),
            let y = numericValue(row[1])
      else {
        return nil
      }
      points.append(SourceRunLinePoint(x: x, y: y))
    }

    guard !points.isEmpty else { return nil }
    return SourceRunLineChart(
      xLabel: table.columns[0],
      yLabel: table.columns[1],
      points: points
    )
  }

  private static func numericValue(_ value: Any) -> Double? {
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return nil
      }
      return number.doubleValue
    }
    if let string = value as? String {
      return Double(string)
    }
    return nil
  }

  private static func stringValue(_ value: Any) -> String {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    case _ as NSNull:
      return ""
    default:
      if JSONSerialization.isValidJSONObject([value]),
         let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
         let text = String(data: data, encoding: .utf8) {
        return text
      }
      return "\(value)"
    }
  }
}

public struct SourceRunTable: Equatable, Sendable {
  public let columns: [String]
  public let rows: [[String]]

  public init(columns: [String], rows: [[String]]) {
    self.columns = columns
    self.rows = rows
  }
}

public struct SourceRunBar: Equatable, Sendable {
  public let label: String
  public let value: Double

  public init(label: String, value: Double) {
    self.label = label
    self.value = value
  }
}

public struct SourceRunLineChart: Equatable, Sendable {
  public let xLabel: String
  public let yLabel: String
  public let points: [SourceRunLinePoint]

  public init(xLabel: String, yLabel: String, points: [SourceRunLinePoint]) {
    self.xLabel = xLabel
    self.yLabel = yLabel
    self.points = points
  }
}

public struct SourceRunLinePoint: Equatable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

private extension Character {
  var isASCIIWord: Bool {
    unicodeScalars.allSatisfy { scalar in
      (65...90).contains(Int(scalar.value))
        || (97...122).contains(Int(scalar.value))
        || (48...57).contains(Int(scalar.value))
    }
  }
}

public enum WorkspaceLocation: Hashable, Sendable {
  case agenda(AgendaItem)
  case assigned(AssignedWorkItem)
  case search(SearchResult)
  case backlink(BacklinkItem)
  case openClaw(OpenClawThread)
  case meeting(MeetingWorkspaceItem)

  public var title: String {
    switch self {
    case .agenda(let item): Org2Display.cleanInline(item.headline)
    case .assigned(let item): Org2Display.cleanInline(item.headline)
    case .search(let result): Org2Display.cleanInline(result.title)
    case .backlink(let backlink): Org2Display.cleanInline(backlink.srcTitle)
    case .openClaw(let thread): Org2Display.cleanInline(thread.title)
    case .meeting(let meeting): Org2Display.cleanInline(meeting.title)
    }
  }

  public var subtitle: String {
    switch self {
    case .agenda(let item): [item.todo, item.kind, item.time].compactMap { $0 }.joined(separator: " ")
    case .assigned(let item): [item.todo, item.status, item.assignee].compactMap { $0 }.joined(separator: " ")
    case .search(let result): Org2Display.cleanInline(result.snippet)
    case .backlink(let backlink): Org2Display.cleanInline(backlink.context)
    case .openClaw(let thread): thread.zone
    case .meeting(let meeting):
      [meeting.recordedAt, meeting.transcriptionStatus].compactMap { $0 }.joined(separator: " ")
    }
  }

  public var file: String {
    switch self {
    case .agenda(let item): item.file
    case .assigned(let item): item.file
    case .search(let result): result.file
    case .backlink(let backlink): backlink.file
    case .openClaw(let thread): thread.file
    case .meeting(let meeting): meeting.file
    }
  }

  public var lineForEditor: Int {
    switch self {
    case .agenda(let item): item.lineForEditor
    case .assigned(let item): item.lineForEditor
    case .search(let result): result.lineForEditor
    case .backlink(let backlink): backlink.lineForEditor
    case .openClaw(let thread): thread.lineForEditor
    case .meeting(let meeting): meeting.lineForEditor
    }
  }

  public var idValue: String? {
    switch self {
    case .agenda(let item): item.idValue
    case .assigned: nil
    case .search(let result): result.idValue
    case .backlink(let backlink): backlink.srcId
    case .openClaw(let thread): thread.idValue
    case .meeting(let meeting): meeting.idValue
    }
  }
}

public enum Org2Display {
  private static let labeledLinkRegex = try! NSRegularExpression(
    pattern: #"\[\[([^\]\n]+)\]\[([^\]\n]*)\]\]"#
  )
  private static let bareLinkRegex = try! NSRegularExpression(
    pattern: #"\[\[([^\]\n]+)\]\]"#
  )
  private static let bareIDRegex = try! NSRegularExpression(
    pattern: #"\bid:([0-9a-fA-F-]{36})\b"#
  )

  public static func cleanInline(_ raw: String) -> String {
    var text = raw
    if text.contains("[[") {
      text = replaceMatches(in: text, regex: labeledLinkRegex) { match in
        guard match.numberOfRanges >= 3 else { return match.fullText(in: text) }
        return match.string(at: 2, in: text)
      }

      text = replaceMatches(in: text, regex: bareLinkRegex) { match in
        guard match.numberOfRanges >= 2 else { return match.fullText(in: text) }
        let target = match.string(at: 1, in: text)
        return cleanTarget(target)
      }
    }

    if text.range(of: "id:", options: .caseInsensitive) != nil {
      text = replaceMatches(in: text, regex: bareIDRegex) { match in
        guard match.numberOfRanges >= 2 else { return match.fullText(in: text) }
        return "id:\(shortID(match.string(at: 1, in: text)))"
      }
    }

    return text
      .replacingOccurrences(of: #"\"#, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func cleanBlock(_ raw: String) -> String {
    raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { cleanInline(String($0)) }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func shortID(_ raw: String) -> String {
    String(raw.prefix(8))
  }

  private static func cleanTarget(_ target: String) -> String {
    if target.hasPrefix("id:") {
      return "id:\(shortID(String(target.dropFirst(3))))"
    }
    if target.hasPrefix("file:") {
      return URL(fileURLWithPath: String(target.dropFirst(5))).lastPathComponent
    }
    return target
  }

  private static func replaceMatches(
    in text: String,
    regex: NSRegularExpression,
    transform: (NSTextCheckingResult) -> String
  ) -> String {
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
    var output = text
    for match in matches {
      guard let range = Range(match.range, in: output) else { continue }
      output.replaceSubrange(range, with: transform(match))
    }
    return output
  }
}

extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func trimmedForDisplay(maxCharacters: Int) -> String {
    let compact = trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    guard compact.count > maxCharacters else { return compact }
    return String(compact.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }
}

private extension NSTextCheckingResult {
  func string(at index: Int, in text: String) -> String {
    guard index < numberOfRanges,
          let range = Range(range(at: index), in: text)
    else {
      return ""
    }
    return String(text[range])
  }

  func fullText(in text: String) -> String {
    guard let range = Range(range, in: text) else { return "" }
    return String(text[range])
  }
}

public struct AgendaDisplaySection: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let items: [AgendaItem]
  public let hint: String?

  public init(id: String, label: String, items: [AgendaItem], hint: String? = nil) {
    self.id = id
    self.label = label
    self.items = items
    self.hint = hint
  }
}

public struct AssignedWorkSection: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let items: [AssignedWorkItem]

  public init(id: String, label: String, items: [AssignedWorkItem]) {
    self.id = id
    self.label = label
    self.items = items
  }
}

public struct MeetingSection: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let meetings: [MeetingWorkspaceItem]

  public init(id: String, label: String, meetings: [MeetingWorkspaceItem]) {
    self.id = id
    self.label = label
    self.meetings = meetings
  }
}

public struct WorkspaceHealthCheck: Identifiable, Equatable, Sendable {
  public enum Status: String, Sendable {
    case ready
    case warning
    case blocking

    public var title: String {
      switch self {
      case .ready: "Ready"
      case .warning: "Warning"
      case .blocking: "Blocked"
      }
    }
  }

  public let id: String
  public let title: String
  public let status: Status
  public let detail: String
  public let remediationTitle: String?

  public init(id: String, title: String, status: Status, detail: String, remediationTitle: String? = nil) {
    self.id = id
    self.title = title
    self.status = status
    self.detail = detail
    self.remediationTitle = remediationTitle
  }
}

public enum AgendaMode: String, CaseIterable, Identifiable, Sendable {
  case focus
  case today
  case range
  case assigned

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .focus: "Focus"
    case .today: "Today"
    case .range: "Range"
    case .assigned: "All Time"
    }
  }
}

public enum TodoEditStatus: String, Sendable {
  case todo
  case inProgress = "in_progress"
  case done
  case canceled

  public var label: String {
    switch self {
    case .todo: "TODO"
    case .inProgress: "IN_PROGRESS"
    case .done: "DONE"
    case .canceled: "CANCELED"
    }
  }
}

public enum PlanningEditKind: String, Sendable {
  case scheduled
  case deadline
}

public enum PlanningDateTarget: Sendable {
  case today
  case tomorrow
  case upcomingMonday
  case nextMonth
}

public enum DetailScrollDirection: Equatable, Sendable {
  case up
  case down
}

public enum DetailScrollTarget: Equatable, Sendable {
  case page(DetailScrollDirection)
  case block(String)
  case revealBlock(String)
  case sourceLine(Int)
}

public struct DetailScrollRequest: Equatable, Sendable {
  public let id: Int
  public let target: DetailScrollTarget

  public init(id: Int, target: DetailScrollTarget) {
    self.id = id
    self.target = target
  }

  public init(id: Int, direction: DetailScrollDirection) {
    self.init(id: id, target: .page(direction))
  }
}

public enum DailyNoteTarget: String, CaseIterable, Identifiable, Sendable {
  case today
  case yesterday
  case tomorrow

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .yesterday: "Yesterday"
    case .today: "Today"
    case .tomorrow: "Tomorrow"
    }
  }

  public var commandShortcutTitle: String {
    switch self {
    case .today: "⌘7"
    case .yesterday: "⌘8"
    case .tomorrow: "⌘9"
    }
  }
}

public struct TodoMutationPayload: Decodable, Sendable {
  public let file: String
  public let headingLine: Int
  public let oldStatus: String
  public let newStatus: String
  public let applied: Bool
  public let changed: Bool
}

public struct TodoAssignmentPayload: Decodable, Sendable {
  public let file: String
  public let headingLine: Int
  public let property: String
  public let oldAssignee: String?
  public let newAssignee: String
  public let applied: Bool
  public let changed: Bool
}

public struct PlanMutationPayload: Decodable, Sendable {
  public let file: String
  public let headingLine: Int
  public let kind: String
  public let date: String
  public let applied: Bool
  public let changed: Bool
}
