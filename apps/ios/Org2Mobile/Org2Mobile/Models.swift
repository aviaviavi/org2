import Foundation

enum OrgTodoStatus: String, CaseIterable {
  case next = "NEXT"
  case todo = "TODO"
  case inProgress = "IN_PROGRESS"
  case prog = "PROG"
  case started = "STARTED"
  case doing = "DOING"
  case wait = "WAIT"
  case waiting = "WAITING"
  case hold = "HOLD"
  case paused = "PAUSED"
  case review = "REVIEW"
  case done = "DONE"
  case canceled = "CANCELED"
  case cancelled = "CANCELLED"

  var isTerminal: Bool {
    switch self {
    case .done, .canceled, .cancelled:
      true
    default:
      false
    }
  }
}

struct OrgDocument: Identifiable, Hashable {
  let id: String
  let url: URL
  let relativePath: String
  let title: String
  let properties: [String: String]
  let body: String
  let nodes: [OrgNode]
}

struct OrgNode: Identifiable, Hashable {
  let id: String
  let title: String
  let todo: String?
  let level: Int
  let line: Int
  let tags: [String]
  let properties: [String: String]
  let planning: [OrgPlanningDate]
  let body: String
  let documentPath: String
}

struct OrgPlanningDate: Identifiable, Hashable {
  let kind: OrgPlanningKind
  let date: String

  var id: String { "\(kind.rawValue):\(date)" }
}

enum OrgPlanningKind: String, Hashable {
  case scheduled = "Scheduled"
  case deadline = "Deadline"
  case timestamp = "Timestamp"
}

struct AgendaEntry: Identifiable, Hashable {
  let id: String
  let title: String
  let todo: String
  let file: String
  let line: Int
  let date: String
  let kind: OrgPlanningKind
  let tags: [String]
  let body: String

  var isOverdue: Bool {
    date < Date.org2TodayString
  }
}

struct ApprovalEntry: Identifiable, Hashable {
  let id: String
  let title: String
  let status: String
  let file: String
  let line: Int?
  let sourceID: String?
  let properties: [String: String]
  let body: String
  let tags: [String]

  var sourceLabel: String {
    if let line {
      "\(file):\(line)"
    } else {
      file
    }
  }

  var whatsappText: String {
    """
    OpenClaw approval thread:

    \(title)
    Source: \(sourceLabel)
    Status: \(status)

    \(body.trimmedForDisplay(maxCharacters: 900))
    """
  }
}

struct NoteAttachment: Identifiable, Hashable {
  let id = UUID()
  let filename: String
  let data: Data
}

enum OpenClawAction: String {
  case approve
  case discuss

  var title: String {
    switch self {
    case .approve:
      "Approve"
    case .discuss:
      "Discuss"
    }
  }
}

extension String {
  func trimmedForDisplay(maxCharacters: Int = 280) -> String {
    let compact = prettyPrintedOrgLinks()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    guard compact.count > maxCharacters else { return compact }
    return String(compact.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }

  func prettyPrintedOrgLinks() -> String {
    let pattern = #"\[\[([^\]\[]+)\](?:\[([^\]\[]*)\])?\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
    let nsRange = NSRange(startIndex..<endIndex, in: self)
    let matches = regex.matches(in: self, range: nsRange).reversed()
    var result = self

    for match in matches {
      guard let matchRange = Range(match.range(at: 0), in: result),
            let targetRange = Range(match.range(at: 1), in: result) else {
        continue
      }
      let target = String(result[targetRange])
      let description: String?
      if match.range(at: 2).location != NSNotFound, let descriptionRange = Range(match.range(at: 2), in: result) {
        description = String(result[descriptionRange])
      } else {
        description = nil
      }

      let replacement = description?.isEmpty == false ? description! : target.prettyOrgLinkTarget()
      result.replaceSubrange(matchRange, with: replacement)
    }

    return result
  }

  private func prettyOrgLinkTarget() -> String {
    for prefix in ["id:", "file:", "attachment:"] {
      if lowercased().hasPrefix(prefix) {
        return String(dropFirst(prefix.count))
      }
    }
    return self
  }
}

extension Date {
  static var org2TodayString: String {
    org2DayFormatter.string(from: Date())
  }

  static let org2DayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
