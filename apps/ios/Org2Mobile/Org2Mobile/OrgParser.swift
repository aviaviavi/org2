import Foundation

enum OrgParser {
  private static let todoKeywords = Set(OrgTodoStatus.allCases.map(\.rawValue))
  private static let terminalTodos = Set(OrgTodoStatus.allCases.filter(\.isTerminal).map(\.rawValue))
  private static let orgExtensions = Set(["org", "org2", "txt"])

  static func isCorpusFile(_ url: URL) -> Bool {
    orgExtensions.contains(url.pathExtension.lowercased())
  }

  static func parseDocument(at url: URL, rootURL: URL) throws -> OrgDocument {
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.components(separatedBy: .newlines)
    let relativePath = relativePath(for: url, rootURL: rootURL)
    let fileTitle = parseTitle(lines: lines) ?? url.deletingPathExtension().lastPathComponent
    let documentProperties = parseDocumentProperties(lines: lines)
    var nodes: [OrgNode] = []

    var index = 0
    while index < lines.count {
      guard let heading = parseHeading(lines[index]) else {
        index += 1
        continue
      }

      let bodyStart = index + 1
      var bodyEnd = bodyStart
      while bodyEnd < lines.count {
        if parseHeading(lines[bodyEnd]) != nil {
          break
        }
        bodyEnd += 1
      }

      let bodyLines = Array(lines[bodyStart..<bodyEnd])
      let properties = parsePropertyDrawer(lines: bodyLines)
      let planning = parsePlanningDates(lines: bodyLines)
      let body = stripPropertyDrawer(from: bodyLines).joined(separator: "\n")
      let line = index + 1
      let nodeID = properties["ID"] ?? "\(relativePath):\(line)"

      nodes.append(
        OrgNode(
          id: nodeID,
          title: heading.title,
          todo: heading.todo,
          level: heading.level,
          line: line,
          tags: heading.tags,
          properties: properties,
          planning: planning,
          body: body,
          documentPath: relativePath
        )
      )

      index = bodyEnd
    }

    return OrgDocument(
      id: relativePath,
      url: url,
      relativePath: relativePath,
      title: fileTitle,
      properties: documentProperties,
      body: text,
      nodes: nodes
    )
  }

  static func agendaEntries(from documents: [OrgDocument], today: String = Date.org2TodayString, days: Int = 7) -> [AgendaEntry] {
    let endDate = Calendar.current.date(byAdding: .day, value: days - 1, to: Date()) ?? Date()
    let end = Date.org2DayFormatter.string(from: endDate)

    return documents.flatMap { document in
      document.nodes.flatMap { node in
        guard let todo = node.todo?.uppercased(), !terminalTodos.contains(todo) else {
          return [AgendaEntry]()
        }

        return node.planning.compactMap { planning in
          guard planning.date <= end else { return nil }
          guard planning.date >= today || planning.kind == .deadline || planning.kind == .scheduled else { return nil }

          return AgendaEntry(
            id: "\(document.relativePath):\(node.line):\(planning.kind.rawValue):\(planning.date)",
            title: node.title,
            todo: todo,
            file: document.relativePath,
            line: node.line,
            date: planning.date,
            kind: planning.kind,
            tags: node.tags,
            body: node.body.trimmedForDisplay(),
          )
        }
      }
    }
    .sorted { lhs, rhs in
      if lhs.date != rhs.date { return lhs.date < rhs.date }
      if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
  }

  static func approvalEntries(from documents: [OrgDocument]) -> [ApprovalEntry] {
    var entries: [ApprovalEntry] = []

    for document in documents {
      for node in document.nodes {
        guard let todo = node.todo?.uppercased(), !terminalTodos.contains(todo) else {
          continue
        }

        if let status = approvalStatus(for: node) {
          entries.append(
            ApprovalEntry(
              id: "\(document.relativePath):\(node.line)",
              title: node.title,
              status: status,
              todo: todo,
              level: node.level,
              file: document.relativePath,
              line: node.line,
              sourceID: node.properties["ID"],
              properties: node.properties,
              body: node.body.prettyPrintedOrgLinks().trimmingCharacters(in: .whitespacesAndNewlines),
              tags: node.tags,
              kind: "headline",
              runID: nil,
              approvalID: nil,
              fingerprint: nil,
              action: nil,
              riskClass: nil,
            )
          )
        }
      }
    }

    return entries.sorted { lhs, rhs in
      if lhs.status != rhs.status { return lhs.status < rhs.status }
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
  }

  static func relativePath(for url: URL, rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }
    let start = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
    return String(filePath[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private static func parseTitle(lines: [String]) -> String? {
    for line in lines.prefix(30) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.lowercased().hasPrefix("#+title:") {
        return String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }

  private static func parseDocumentProperties(lines: [String]) -> [String: String] {
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" }) else {
      return [:]
    }
    let earlierHeading = lines[..<start].contains { parseHeading($0) != nil }
    guard !earlierHeading else { return [:] }
    return parsePropertyDrawer(lines: Array(lines[start...]))
  }

  private static func parseHeading(_ line: String) -> (level: Int, todo: String?, title: String, tags: [String])? {
    let stars = line.prefix { $0 == "*" }.count
    guard stars > 0 else { return nil }
    let afterStars = line.dropFirst(stars)
    guard afterStars.first?.isWhitespace == true else { return nil }

    var rest = afterStars.trimmingCharacters(in: .whitespaces)
    var todo: String?
    if let first = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first {
      let token = String(first).uppercased()
      if todoKeywords.contains(token) {
        todo = token
        rest = rest.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
      }
    }

    if rest.hasPrefix("[#"), let close = rest.firstIndex(of: "]") {
      rest = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }

    var tags: [String] = []
    if let range = rest.range(of: #"\s+(:[A-Za-z0-9_@#%.-]+(?::[A-Za-z0-9_@#%.-]+)*:)\s*$"#, options: .regularExpression) {
      let tagText = String(rest[range]).trimmingCharacters(in: .whitespaces)
      tags = tagText.split(separator: ":").map(String.init)
      rest.removeSubrange(range)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    return (stars, todo, rest, tags)
  }

  private static func parsePropertyDrawer(lines: [String]) -> [String: String] {
    var properties: [String: String] = [:]
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" }) else {
      return properties
    }

    var index = lines.index(after: start)
    while index < lines.endIndex {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed.uppercased() == ":END:" { break }
      if trimmed.hasPrefix(":"), let secondColon = trimmed.dropFirst().firstIndex(of: ":") {
        let keyStart = trimmed.index(after: trimmed.startIndex)
        let key = String(trimmed[keyStart..<secondColon]).uppercased()
        let valueStart = trimmed.index(after: secondColon)
        let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
          properties[key] = value
        }
      }
      index = lines.index(after: index)
    }

    return properties
  }

  private static func stripPropertyDrawer(from lines: [String]) -> [String] {
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" }) else {
      return lines
    }

    var end = start
    while end < lines.endIndex {
      if lines[end].trimmingCharacters(in: .whitespaces).uppercased() == ":END:" {
        return Array(lines[..<start] + lines[lines.index(after: end)...])
      }
      end = lines.index(after: end)
    }
    return lines
  }

  private static func parsePlanningDates(lines: [String]) -> [OrgPlanningDate] {
    var dates: [OrgPlanningDate] = []
    for line in lines.prefix(80) {
      dates.append(contentsOf: planningMatches(in: line, label: "SCHEDULED", kind: .scheduled))
      dates.append(contentsOf: planningMatches(in: line, label: "DEADLINE", kind: .deadline))
    }
    return Array(Set(dates)).sorted { lhs, rhs in
      if lhs.date != rhs.date { return lhs.date < rhs.date }
      return lhs.kind.rawValue < rhs.kind.rawValue
    }
  }

  private static func planningMatches(in line: String, label: String, kind: OrgPlanningKind) -> [OrgPlanningDate] {
    let pattern = #"\#(label):\s*<(\d{4}-\d{2}-\d{2})[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    return regex.matches(in: line, range: range).compactMap { match in
      guard let dateRange = Range(match.range(at: 1), in: line) else { return nil }
      return OrgPlanningDate(kind: kind, date: String(line[dateRange]))
    }
  }

  private static func reviewStatus(in properties: [String: String]) -> String? {
    propertyText(
      in: properties,
      keys: [
        "ORG2_REVIEW_STATUS",
        "REVIEW_STATUS",
        "REVIEW",
        "STATUS",
        "FOLLOWUP_STATUS",
        "REPLY_STATUS",
      ]
    ).nilIfBlank
  }

  private static func approvalStatus(for node: OrgNode) -> String? {
    let status = reviewStatus(in: node.properties)
    if let status, isPendingReview(status), titleNeedsHumanApproval(node.title) {
      return status
    }

    let waitingOn = propertyText(in: node.properties, keys: ["WAITING_ON", "BLOCKED_BY", "ORG2_WAITING_ON"])
    if containsApprovalSignal(waitingOn) {
      return waitingOn.isEmpty ? "approval-required" : waitingOn
    }

    let nextAction = propertyText(in: node.properties, keys: ["NEXT_ACTION", "ACTION_REQUIRED", "ORG2_NEXT_ACTION"])
    if containsApprovalSignal(nextAction) {
      return "approval-required"
    }

    let handoff = propertyText(in: node.properties, keys: ["HANDOFF_SUMMARY", "ORG2_HANDOFF_SUMMARY"])
    if containsApprovalSignal(handoff) {
      return "approval-required"
    }

    let accessPolicy = propertyText(in: node.properties, keys: ["ACCESS_POLICY", "REVIEW_POLICY"])
    if isPendingReview(accessPolicy) || containsApprovalSignal(accessPolicy) {
      return accessPolicy.isEmpty ? "approval-required" : accessPolicy
    }

    return nil
  }

  private static func isPendingReview(_ status: String) -> Bool {
    let normalized = status.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if [
      "review-required",
      "requires-review",
      "approval-required",
      "needs-approval",
      "needs-review",
      "pending-review",
      "pending-approval",
      "require-approval",
      "generated",
      "draft",
    ].contains(normalized) {
      return true
    }

    return normalized.contains("needs-review")
      || normalized.contains("need-review")
      || normalized.contains("needs-approval")
      || normalized.contains("need-approval")
      || normalized.contains("waiting-on-approval")
      || normalized.contains("pending-review")
      || normalized.contains("pending-approval")
      || normalized.contains("draft-needs-review")
      || normalized.contains("draft-needs-approval")
      || normalized.contains("reply-review")
      || normalized.contains("needs-avi")
      || normalized.contains("avi-approval")
      || normalized.contains("needs-human")
      || normalized.contains("human-review")
  }

  private static func titleNeedsHumanApproval(_ title: String) -> Bool {
    let normalized = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.hasPrefix("approve ")
      || normalized.hasPrefix("review ")
      || normalized.hasPrefix("review/")
      || normalized.hasPrefix("review-send ")
      || normalized.hasPrefix("review and approve ")
      || normalized.hasPrefix("review/approve ")
  }

  private static func propertyText(in properties: [String: String], keys: [String]) -> String {
    for key in keys {
      if let value = properties[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
      }
    }
    return ""
  }

  private static func containsApprovalSignal(_ text: String) -> Bool {
    let normalized = text.lowercased()
    return normalized.contains("approval")
      || normalized.contains("approve")
      || normalized.contains("review")
      || normalized.contains("avi")
  }

}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
