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

public struct OpenClawChatMessage: Identifiable, Hashable, Codable, Sendable {
  public enum Role: String, Codable, Sendable {
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
    let pattern = #"(?<![A-Za-z0-9_./~-])((?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:[:#](\d+))?"#
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
      || lowercased.range(of: #"\.(?:org2?|md)(?:[:#]\d+)?$"#, options: .regularExpression) != nil
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
    if let regex = try? NSRegularExpression(pattern: #"^(.*\.(?:org2?|md))[:#](\d+)$"#),
       let match = regex.firstMatch(in: path, range: fullRange),
       match.numberOfRanges == 3 {
      let cleanPath = nsPath.substring(with: match.range(at: 1))
      let line = Int(nsPath.substring(with: match.range(at: 2)))
      return (cleanPath, line)
    }

    return (path, nil)
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
    let textLength = (rawText as NSString).length
    guard shouldScanFocusedToken(utf16Length: textLength, maxUTF16Length: maxUTF16Length) else {
      return nil
    }

    let tokens = all(in: rawText)
    guard !tokens.isEmpty else { return nil }
    let safeSelection = NSRange(
      location: min(max(0, selection.location), textLength),
      length: min(max(0, selection.length), max(0, textLength - selection.location))
    )

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
  public static func parse(_ raw: String) -> [OrgInlineSpan] {
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
      if let parsed = parseBracketLink(raw, at: cursor) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseMarkdownLink(raw, at: cursor) {
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
    raw.rangeOfCharacter(from: inlineSyntaxCandidateCharacters) != nil
      || raw.range(of: "http://") != nil
      || raw.range(of: "https://") != nil
      || raw.range(of: ".org") != nil
      || raw.range(of: ".md") != nil
  }

  private enum DelimitedKind {
    case code
    case bold
    case italic
    case underline
    case strike
  }

  private static func parseBracketLink(_ raw: String, at cursor: String.Index) -> (span: OrgInlineSpan, end: String.Index)? {
    guard raw[cursor...].hasPrefix("[[") else { return nil }
    let bodyStart = raw.index(cursor, offsetBy: 2)
    guard let closeRange = raw[bodyStart...].range(of: "]]") else { return nil }
    let body = String(raw[bodyStart..<closeRange.lowerBound])
    let parts = body.components(separatedBy: "][")
    guard let target = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
      return nil
    }
    let label = parts.dropFirst().joined(separator: "][").trimmingCharacters(in: .whitespacesAndNewlines)
    let display = label.isEmpty ? target : label
    return (
      .link(label: display, target: target, fileReference: OpenClawFileReference.fromLinkTarget(target)),
      closeRange.upperBound
    )
  }

  private static func parseMarkdownLink(_ raw: String, at cursor: String.Index) -> (span: OrgInlineSpan, end: String.Index)? {
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
    return (
      .link(label: label, target: target, fileReference: OpenClawFileReference.fromLinkTarget(target)),
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
  private static let inlineSyntaxCandidateCharacters = CharacterSet(charactersIn: "[]<>`~=*/_+")
  private static let timestampBodyRegex = try! NSRegularExpression(
    pattern: #"^(\d{4}-\d{2}-\d{2})(?:\s+[A-Za-z]{3})?(?:\s+(\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?))?(.*)$"#
  )
  private static let fileReferenceRegex = try! NSRegularExpression(
    pattern: #"^((?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:[:#](\d+))?"#
  )
}

public struct OrgMediaAttachment: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case image
    case video
  }

  public let kind: Kind
  public let label: String
  public let target: String
  public let resolvedPath: String?

  public var resolvedURL: URL? {
    resolvedPath.map { URL(fileURLWithPath: $0) }
  }

  public var displayName: String {
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedLabel.isEmpty {
      return trimmedLabel
    }
    let cleaned = Self.cleanTarget(target)
    let name = URL(fileURLWithPath: cleaned).lastPathComponent
    return name.isEmpty ? target : name
  }

  public static func standalone(
    raw: String,
    sourceFile: String? = nil,
    corpusRoot: URL? = nil
  ) -> OrgMediaAttachment? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
    guard let link = standaloneLink(trimmed) else { return nil }
    guard let kind = kind(forTarget: link.target) else { return nil }
    guard !isRemoteURL(link.target) else { return nil }

    return OrgMediaAttachment(
      kind: kind,
      label: link.label,
      target: link.target,
      resolvedPath: resolvePath(link.target, sourceFile: sourceFile, corpusRoot: corpusRoot)
    )
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

  public static func kind(forTarget target: String) -> Kind? {
    let ext = URL(fileURLWithPath: cleanTarget(target)).pathExtension.lowercased()
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

  private static func isRemoteURL(_ target: String) -> Bool {
    guard let url = URL(string: target),
          let scheme = url.scheme?.lowercased()
    else {
      return false
    }
    return scheme == "http" || scheme == "https"
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
