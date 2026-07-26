import CryptoKit
import Foundation

enum ApprovalBinding: String, Codable, Hashable {
  case legacyHeadline = "legacy-headline"
}

struct LegacyPairedApprovalAction: Codable, Hashable {
  enum Mode: String, Codable, Hashable {
    case existing
    case create
  }

  let mode: Mode
  let title: String
  let todo: String?
  let properties: [String: String]
  let body: String
  let line: Int?
}

struct LegacyHeadlineApprovalFingerprintInput: Codable, Hashable {
  let title: String
  let body: String
  let properties: [String: String]
  let status: String
  let todo: String?
  let pairedAction: LegacyPairedApprovalAction?
}

struct LegacyHeadlineApprovalSnapshot: Hashable {
  let headingIndex: Int
  let level: Int
  let title: String
  let status: String
  let todo: String?
  let tags: [String]
  let properties: [String: String]
  let body: String
  let approvalID: String?
  let sourceID: String?
  let fingerprintInput: LegacyHeadlineApprovalFingerprintInput
  let fingerprint: String
  let pairedAction: LegacyPairedApprovalAction?
  let approvalBlockedReason: String?

  var canApprove: Bool {
    approvalBlockedReason == nil
  }
}

struct LegacyHeadlineApprovalReference: Hashable {
  let approvalID: String?
  let sourceID: String?
  let line: Int?
  let fingerprint: String
}

enum LegacyHeadlineApprovalResolutionError: LocalizedError, Equatable {
  case missing
  case ambiguous
  case stale
  case blocked(String)

  var errorDescription: String? {
    switch self {
    case .missing:
      "This approval no longer exists. Refresh before deciding."
    case .ambiguous:
      "This approval is ambiguous on disk. Give it a stable ORG2_APPROVAL_ID before deciding."
    case .stale:
      "This approval changed on disk. Refresh and review the current entry before deciding."
    case .blocked(let reason):
      reason
    }
  }
}

enum ApprovalSemantics {
  private static let todoKeywords = Set(OrgTodoStatus.allCases.map(\.rawValue))
  private static let terminalTodos = Set(OrgTodoStatus.allCases.filter(\.isTerminal).map(\.rawValue))

  static func rowIdentity(
    file: String,
    line: Int,
    approvalID: String?,
    sourceID: String?
  ) -> String {
    if let approvalID = nonblank(approvalID) {
      return "approval:\(approvalID)"
    }
    if let sourceID = nonblank(sourceID) {
      return "source:\(sourceID)"
    }
    return "provisional:\(file):\(line)"
  }

  static func fingerprint(for input: LegacyHeadlineApprovalFingerprintInput) -> String {
    let pairedAction: CanonicalJSON
    if let action = input.pairedAction {
      pairedAction = .object([
        "mode": .string(action.mode.rawValue),
        "title": .string(action.title),
        "todo": action.todo.map(CanonicalJSON.string) ?? .null,
        "properties": .object(action.properties.mapValues(CanonicalJSON.string)),
        "body": .string(action.body),
      ])
    } else {
      pairedAction = .null
    }

    let action = CanonicalJSON.object([
      "body": .string(input.body),
      "properties": .object(input.properties.mapValues(CanonicalJSON.string)),
      "status": .string(input.status),
      "todo": input.todo.map(CanonicalJSON.string) ?? .null,
      "pairedAction": pairedAction,
    ]).encoded

    let source = CanonicalJSON.object([
      "title": .string(input.title),
      "action": .string(action),
      "riskClass": .string("canonical-write"),
      "requestedRole": .null,
      "requestedFrom": .null,
      "note": .null,
      "material": .null,
    ]).encoded

    let digest = SHA256.hash(data: Data(source.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  static func snapshots(in raw: String) -> [LegacyHeadlineApprovalSnapshot] {
    snapshots(in: normalizedLines(in: raw))
  }

  static func resolve(
    in raw: String,
    reference: LegacyHeadlineApprovalReference,
    requireApprovable: Bool = true
  ) throws -> LegacyHeadlineApprovalSnapshot {
    let snapshots = snapshots(in: raw)
    let matches: [LegacyHeadlineApprovalSnapshot]

    if let approvalID = nonblank(reference.approvalID) {
      matches = snapshots.filter { $0.approvalID == approvalID }
    } else if let sourceID = nonblank(reference.sourceID) {
      matches = snapshots.filter { $0.sourceID == sourceID }
    } else {
      let fingerprintMatches = snapshots.filter { $0.fingerprint == reference.fingerprint }
      if fingerprintMatches.count == 1 {
        matches = fingerprintMatches
      } else if fingerprintMatches.count > 1 {
        throw LegacyHeadlineApprovalResolutionError.ambiguous
      } else if let line = reference.line,
                let lineSnapshot = snapshots.first(where: { $0.headingIndex == line - 1 }) {
        if lineSnapshot.fingerprint != reference.fingerprint {
          throw LegacyHeadlineApprovalResolutionError.stale
        }
        matches = [lineSnapshot]
      } else {
        throw LegacyHeadlineApprovalResolutionError.missing
      }
    }

    guard matches.count == 1, let snapshot = matches.first else {
      if matches.count > 1 {
        throw LegacyHeadlineApprovalResolutionError.ambiguous
      }
      throw LegacyHeadlineApprovalResolutionError.missing
    }
    guard snapshot.fingerprint == reference.fingerprint else {
      throw LegacyHeadlineApprovalResolutionError.stale
    }
    if requireApprovable, let reason = snapshot.approvalBlockedReason {
      throw LegacyHeadlineApprovalResolutionError.blocked(reason)
    }
    return snapshot
  }

  private static func snapshots(in lines: [String]) -> [LegacyHeadlineApprovalSnapshot] {
    let headlines = parsedHeadlines(in: lines)
    let snapshots: [LegacyHeadlineApprovalSnapshot] = headlines.compactMap { headline in
      guard !terminalTodos.contains(headline.todo ?? ""),
            let status = approvalStatus(title: headline.title, properties: headline.properties)
      else {
        return nil
      }

      let pairing = pairedAction(
        for: headline,
        among: headlines
      )
      let blockedReasons = [
        pairing.blockedReason,
        headline.duplicatePropertyKeys.isEmpty
          ? nil
          : "The approval property drawer repeats \(headline.duplicatePropertyKeys.joined(separator: ", ")). Normalize duplicate properties before approving.",
      ].compactMap { $0 }
      let fingerprintInput = LegacyHeadlineApprovalFingerprintInput(
        title: headline.title,
        body: headline.subtreeBody,
        properties: headline.properties,
        status: status,
        todo: headline.todo,
        pairedAction: pairing.action
      )
      return LegacyHeadlineApprovalSnapshot(
        headingIndex: headline.index,
        level: headline.level,
        title: headline.title,
        status: status,
        todo: headline.todo,
        tags: headline.tags,
        properties: headline.properties,
        body: headline.subtreeBody,
        approvalID: nonblank(headline.properties["ORG2_APPROVAL_ID"]),
        sourceID: nonblank(headline.properties["ID"]),
        fingerprintInput: fingerprintInput,
        fingerprint: fingerprint(for: fingerprintInput),
        pairedAction: pairing.action,
        approvalBlockedReason: blockedReasons.isEmpty ? nil : blockedReasons.joined(separator: " ")
      )
    }
    let identityCounts = snapshots.reduce(into: [String: Int]()) { counts, snapshot in
      let identity = snapshot.approvalID.map { "approval:\($0)" }
        ?? snapshot.sourceID.map { "source:\($0)" }
      if let identity {
        counts[identity, default: 0] += 1
      }
    }
    return snapshots.map { snapshot in
      let identity = snapshot.approvalID.map { "approval:\($0)" }
        ?? snapshot.sourceID.map { "source:\($0)" }
      guard let identity, identityCounts[identity, default: 0] > 1 else { return snapshot }
      let reason = "This approval identity is duplicated in the file. Give each approval a unique ORG2_APPROVAL_ID before deciding."
      return LegacyHeadlineApprovalSnapshot(
        headingIndex: snapshot.headingIndex,
        level: snapshot.level,
        title: snapshot.title,
        status: snapshot.status,
        todo: snapshot.todo,
        tags: snapshot.tags,
        properties: snapshot.properties,
        body: snapshot.body,
        approvalID: snapshot.approvalID,
        sourceID: snapshot.sourceID,
        fingerprintInput: snapshot.fingerprintInput,
        fingerprint: snapshot.fingerprint,
        pairedAction: snapshot.pairedAction,
        approvalBlockedReason: [snapshot.approvalBlockedReason, reason].compactMap { $0 }.joined(separator: " ")
      )
    }
  }

  private struct ParsedHeadline {
    let index: Int
    let level: Int
    let todo: String?
    let title: String
    let tags: [String]
    let properties: [String: String]
    let duplicatePropertyKeys: [String]
    let subtreeBody: String
    let sectionBody: String
  }

  private static func parsedHeadlines(in lines: [String]) -> [ParsedHeadline] {
    let parsed = lines.indices.compactMap { index -> (index: Int, heading: (level: Int, todo: String?, title: String, tags: [String]))? in
      guard let heading = parseHeadline(lines[index]) else { return nil }
      return (index, heading)
    }
    var result: [ParsedHeadline] = []
    for (offset, item) in parsed.enumerated() {
      let index = item.index
      let heading = item.heading
      let following = parsed.dropFirst(offset + 1)
      let sectionEnd = following.first?.index ?? lines.endIndex
      let subtreeEnd = following.first(where: { $0.heading.level <= heading.level })?.index ?? lines.endIndex
      let drawer = propertyDrawer(in: lines, headingIndex: index, endIndex: sectionEnd)
      result.append(
        ParsedHeadline(
          index: index,
          level: heading.level,
          todo: heading.todo,
          title: heading.title,
          tags: heading.tags,
          properties: drawer.properties,
          duplicatePropertyKeys: drawer.duplicateKeys,
          subtreeBody: body(
            in: lines,
            headingIndex: index,
            endIndex: subtreeEnd,
            sectionEndIndex: sectionEnd,
            propertyDrawerRange: drawer.range
          ),
          sectionBody: body(
            in: lines,
            headingIndex: index,
            endIndex: sectionEnd,
            sectionEndIndex: sectionEnd,
            propertyDrawerRange: drawer.range
          )
        )
      )
    }
    return result
  }

  private static func parseHeadline(_ line: String) -> (level: Int, todo: String?, title: String, tags: [String])? {
    let level = line.prefix { $0 == "*" }.count
    guard level > 0, line.dropFirst(level).first?.isWhitespace == true else { return nil }

    var rest = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
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
    if let range = rest.range(
      of: #"\s+(:[A-Za-z0-9_@#%.-]+(?::[A-Za-z0-9_@#%.-]+)*:)\s*$"#,
      options: .regularExpression
    ) {
      let tagText = String(rest[range]).trimmingCharacters(in: .whitespaces)
      tags = tagText.split(separator: ":").map(String.init)
      rest.removeSubrange(range)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    return (level, todo, inlineOrgText(String(rest)), tags)
  }

  private static func inlineOrgText(_ value: String) -> String {
    let pattern = #"\[\[([^\]\[]+)\](?:\[([^\]\[]*)\])?\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    var result = value
    let matches = regex.matches(
      in: value,
      range: NSRange(value.startIndex..<value.endIndex, in: value)
    ).reversed()
    for match in matches {
      guard let wholeRange = Range(match.range(at: 0), in: result),
            let targetRange = Range(match.range(at: 1), in: result)
      else {
        continue
      }
      let replacement: String
      if match.range(at: 2).location != NSNotFound,
         let descriptionRange = Range(match.range(at: 2), in: result) {
        replacement = String(result[descriptionRange])
      } else {
        replacement = String(result[targetRange])
      }
      result.replaceSubrange(wholeRange, with: replacement)
    }
    return result
  }

  private static func propertyDrawer(
    in lines: [String],
    headingIndex: Int,
    endIndex: Int
  ) -> (properties: [String: String], duplicateKeys: [String], range: Range<Int>?) {
    guard headingIndex + 1 < endIndex,
          let start = lines[(headingIndex + 1)..<endIndex].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:"
          })
    else {
      return ([:], [], nil)
    }

    var properties: [String: String] = [:]
    var duplicateKeys = Set<String>()
    var index = start + 1
    var drawerEnd: Int?
    while index < endIndex {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed.uppercased() == ":END:" {
        drawerEnd = index + 1
        break
      }
      if trimmed.hasPrefix(":"),
         let secondColon = trimmed.dropFirst().firstIndex(of: ":") {
        let keyStart = trimmed.index(after: trimmed.startIndex)
        let key = String(trimmed[keyStart..<secondColon]).uppercased()
        let valueStart = trimmed.index(after: secondColon)
        if !key.isEmpty {
          if properties[key] != nil {
            duplicateKeys.insert(key)
          }
          properties[key] = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
        }
      }
      index += 1
    }
    return (
      properties,
      duplicateKeys.sorted(by: utf8LessThan),
      drawerEnd.map { start..<$0 }
    )
  }

  private static func body(
    in lines: [String],
    headingIndex: Int,
    endIndex: Int,
    sectionEndIndex: Int,
    propertyDrawerRange: Range<Int>?
  ) -> String {
    var result: [String] = []
    guard headingIndex + 1 < endIndex else { return "" }

    for index in (headingIndex + 1)..<endIndex {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if propertyDrawerRange?.contains(index) == true {
        continue
      }
      if index < sectionEndIndex, trimmed.range(
        of: #"^(?:SCHEDULED|DEADLINE|CLOSED):\s*"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil {
        continue
      }
      result.append(line)
    }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func approvalStatus(title: String, properties: [String: String]) -> String? {
    let decision = properties["ORG2_APPROVAL_DECISION"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if let decision, ["approved", "rejected", "revised", "canceled"].contains(decision) {
      return nil
    }

    let status = propertyText(
      properties,
      keys: [
        "ORG2_REVIEW_STATUS",
        "REVIEW_STATUS",
        "REVIEW",
        "STATUS",
        "FOLLOWUP_STATUS",
        "REPLY_STATUS",
      ]
    )
    if let status = nonblank(status),
       isPendingReview(status),
       titleNeedsHumanApproval(title) {
      return status
    }

    let waitingOn = propertyText(properties, keys: ["WAITING_ON", "BLOCKED_BY", "ORG2_WAITING_ON"])
    if containsApprovalSignal(waitingOn) {
      return nonblank(waitingOn) ?? "approval-required"
    }
    let nextAction = propertyText(properties, keys: ["NEXT_ACTION", "ACTION_REQUIRED", "ORG2_NEXT_ACTION"])
    if containsApprovalSignal(nextAction) {
      return "approval-required"
    }
    let handoff = propertyText(properties, keys: ["HANDOFF_SUMMARY", "ORG2_HANDOFF_SUMMARY"])
    if containsApprovalSignal(handoff) {
      return "approval-required"
    }
    let accessPolicy = propertyText(properties, keys: ["ACCESS_POLICY", "REVIEW_POLICY"])
    if isPendingReview(accessPolicy) || containsApprovalSignal(accessPolicy) {
      return nonblank(accessPolicy) ?? "approval-required"
    }
    return nil
  }

  private static func propertyText(_ properties: [String: String], keys: [String]) -> String {
    for key in keys {
      if let value = nonblank(properties[key]) {
        return value
      }
    }
    return ""
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

  private static func containsApprovalSignal(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return normalized.contains("approval")
      || normalized.contains("approve")
      || normalized.contains("review")
      || normalized.contains("avi")
  }

  private static func pairedAction(
    for approval: ParsedHeadline,
    among headlines: [ParsedHeadline]
  ) -> (action: LegacyPairedApprovalAction?, blockedReason: String?) {
    let explicitTitles = [
      "PAIRED_SEND_TODO",
      "PAIRED_AGENT_TODO",
      "PAIRED_TODO",
      "NEXT_AGENT_TODO",
      "SEND_TODO",
    ].compactMap { nonblank(approval.properties[$0]) }
    let distinctExplicitTitles = Dictionary(
      explicitTitles.map { (normalizedTitle($0), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    if distinctExplicitTitles.count > 1 {
      return (
        nil,
        "The approval declares conflicting paired agent actions. Keep one stable paired-action pointer before approving."
      )
    }

    if explicitTitles.isEmpty,
       approval.level > 1,
       approval.title.range(of: #"^Approve\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
      for candidate in headlines.reversed() where candidate.index < approval.index {
        guard candidate.level < approval.level else { continue }
        guard isApprovedAgentActionTitle(candidate.title) else { return (nil, nil) }
        let action = LegacyPairedApprovalAction(
            mode: .existing,
            title: candidate.title,
            todo: candidate.todo,
            properties: candidate.properties,
            body: candidate.sectionBody,
            line: candidate.index + 1
        )
        return (action, pairedActionBlockedReason(for: candidate))
      }
    }

    let intendedTitle = explicitTitles.first
      ?? (isApprovalTitle(approval.title) ? approvedAgentActionTitle(approval.title) : nil)
    guard let intendedTitle else { return (nil, nil) }
    let normalizedTitles = Set((explicitTitles.isEmpty ? [intendedTitle] : explicitTitles).map(normalizedTitle))
    let matches = headlines.filter {
      $0.index != approval.index && normalizedTitles.contains(normalizedTitle($0.title))
    }
    if matches.count > 1 {
      return (
        nil,
        "The paired agent action is ambiguous. Give it a unique title or stable pointer before approving."
      )
    }
    guard let match = matches.first else {
      return (
        LegacyPairedApprovalAction(
          mode: .create,
          title: intendedTitle,
          todo: "TODO",
          properties: [:],
          body: "",
          line: nil
        ),
        nil
      )
    }
    let action = LegacyPairedApprovalAction(
        mode: .existing,
        title: match.title,
        todo: match.todo,
        properties: match.properties,
        body: match.sectionBody,
        line: match.index + 1
    )
    return (action, pairedActionBlockedReason(for: match))
  }

  private static func pairedActionBlockedReason(for headline: ParsedHeadline) -> String? {
    var reasons: [String] = []
    if terminalTodos.contains(headline.todo ?? "") || hasSentEvidence(headline.properties) {
      reasons.append("The paired agent action is already terminal or has send evidence and will not be reopened.")
    }
    if !headline.duplicatePropertyKeys.isEmpty {
      reasons.append(
        "The paired agent action repeats \(headline.duplicatePropertyKeys.joined(separator: ", ")). Normalize duplicate properties before approving."
      )
    }
    return reasons.isEmpty ? nil : reasons.joined(separator: " ")
  }

  private static func hasSentEvidence(_ properties: [String: String]) -> Bool {
    for key in ["SENT_AT", "LAST_SENT_AT", "GMAIL_SENT_MESSAGE_ID", "FOLLOWUP_SENT_AT"] {
      if nonblank(properties[key]) != nil { return true }
    }
    let status = properties["STATUS"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    return ["sent", "bounced", "bounce", "contact-route", "contact-route-needed", "contact-route-missing"]
      .contains(status)
  }

  private static func normalizedTitle(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .lowercased()
  }

  private static func isApprovalTitle(_ title: String) -> Bool {
    title.range(of: #"^Approve\b"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private static func isApprovedAgentActionTitle(_ title: String) -> Bool {
    title.range(
      of: #"^(Send approved|Continue approved)\b"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  private static func approvedAgentActionTitle(_ approvalTitle: String) -> String {
    let clean = approvalTitle
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.range(of: #"^approve\s+"#, options: [.regularExpression, .caseInsensitive]) != nil {
      let remainder = clean.replacingOccurrences(
        of: #"^approve\s+"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      return remainder.isEmpty ? "Continue approved task" : "Send approved \(remainder)"
    }
    return "Continue approved \(clean.isEmpty ? "task" : clean)"
  }

  private static func normalizedLines(in raw: String) -> [String] {
    raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
  }

  private static func nonblank(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func utf8LessThan(_ lhs: String, _ rhs: String) -> Bool {
    Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
  }
}

private indirect enum CanonicalJSON {
  case string(String)
  case object([String: CanonicalJSON])
  case null

  var encoded: String {
    switch self {
    case .string(let value):
      return "\"\(Self.escaped(value))\""
    case .object(let object):
      let fields = object.keys.sorted(by: Self.utf8LessThan).map { key in
        "\"\(Self.escaped(key))\":\(object[key]!.encoded)"
      }
      return "{\(fields.joined(separator: ","))}"
    case .null:
      return "null"
    }
  }

  private static func utf8LessThan(_ lhs: String, _ rhs: String) -> Bool {
    Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
  }

  private static func escaped(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count + 2)
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x08:
        result += "\\b"
      case 0x09:
        result += "\\t"
      case 0x0A:
        result += "\\n"
      case 0x0C:
        result += "\\f"
      case 0x0D:
        result += "\\r"
      case 0x22:
        result += "\\\""
      case 0x5C:
        result += "\\\\"
      case 0x00...0x1F:
        result += String(format: "\\u%04x", scalar.value)
      default:
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
