import Foundation

public struct AgendaPayload: Decodable, Sendable {
  public let schema: String?
  public let range: AgendaRange
  public let overdue: [AgendaDay]
  public let days: [AgendaDay]
  public let skippedFiles: Int?
  public let workload: AgendaWorkload?

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case range
    case overdue
    case days
    case skippedFiles
    case workload
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

  public func matchesAgendaFilter(_ query: String) -> Bool {
    let terms = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)

    guard !terms.isEmpty else { return true }

    let haystack = [
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

    return terms.allSatisfy { haystack.contains($0) }
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

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case query
    case mode
    case sort
    case results
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

public struct OpenClawChatMessage: Identifiable, Hashable, Sendable {
  public enum Role: String, Sendable {
    case user
    case assistant
    case system
  }

  public let id: UUID
  public let role: Role
  public let content: String
  public let createdAt: Date

  public init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date()) {
    self.id = id
    self.role = role
    self.content = content
    self.createdAt = createdAt
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

public enum WorkspaceLocation: Hashable, Sendable {
  case agenda(AgendaItem)
  case search(SearchResult)
  case backlink(BacklinkItem)
  case openClaw(OpenClawThread)

  public var title: String {
    switch self {
    case .agenda(let item): Org2Display.cleanInline(item.headline)
    case .search(let result): Org2Display.cleanInline(result.title)
    case .backlink(let backlink): Org2Display.cleanInline(backlink.srcTitle)
    case .openClaw(let thread): Org2Display.cleanInline(thread.title)
    }
  }

  public var subtitle: String {
    switch self {
    case .agenda(let item): [item.todo, item.kind, item.time].compactMap { $0 }.joined(separator: " ")
    case .search(let result): Org2Display.cleanInline(result.snippet)
    case .backlink(let backlink): Org2Display.cleanInline(backlink.context)
    case .openClaw(let thread): thread.zone
    }
  }

  public var file: String {
    switch self {
    case .agenda(let item): item.file
    case .search(let result): result.file
    case .backlink(let backlink): backlink.file
    case .openClaw(let thread): thread.file
    }
  }

  public var lineForEditor: Int {
    switch self {
    case .agenda(let item): item.lineForEditor
    case .search(let result): result.lineForEditor
    case .backlink(let backlink): backlink.lineForEditor
    case .openClaw(let thread): thread.lineForEditor
    }
  }

  public var idValue: String? {
    switch self {
    case .agenda(let item): item.idValue
    case .search(let result): result.idValue
    case .backlink(let backlink): backlink.srcId
    case .openClaw(let thread): thread.idValue
    }
  }
}

public enum Org2Display {
  public static func cleanInline(_ raw: String) -> String {
    var text = raw
    text = replaceMatches(
      in: text,
      pattern: #"\[\[([^\]\n]+)\]\[([^\]\n]*)\]\]"#
    ) { match in
      guard match.numberOfRanges >= 3 else { return match.fullText(in: text) }
      return match.string(at: 2, in: text)
    }

    text = replaceMatches(
      in: text,
      pattern: #"\[\[([^\]\n]+)\]\]"#
    ) { match in
      guard match.numberOfRanges >= 2 else { return match.fullText(in: text) }
      let target = match.string(at: 1, in: text)
      return cleanTarget(target)
    }

    text = replaceMatches(
      in: text,
      pattern: #"\bid:([0-9a-fA-F-]{36})\b"#
    ) { match in
      guard match.numberOfRanges >= 2 else { return match.fullText(in: text) }
      return "id:\(shortID(match.string(at: 1, in: text)))"
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
    pattern: String,
    transform: (NSTextCheckingResult) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
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

public struct OpenClawThreadSection: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let threads: [OpenClawThread]

  public init(id: String, label: String, threads: [OpenClawThread]) {
    self.id = id
    self.label = label
    self.threads = threads
  }
}

public enum AgendaMode: String, CaseIterable, Identifiable, Sendable {
  case focus
  case today
  case range

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .focus: "Focus"
    case .today: "Today"
    case .range: "Range"
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

public enum DailyNoteTarget: String, CaseIterable, Identifiable, Sendable {
  case yesterday
  case today
  case tomorrow

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .yesterday: "Yesterday"
    case .today: "Today"
    case .tomorrow: "Tomorrow"
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

public struct PlanMutationPayload: Decodable, Sendable {
  public let file: String
  public let headingLine: Int
  public let kind: String
  public let date: String
  public let applied: Bool
  public let changed: Bool
}
